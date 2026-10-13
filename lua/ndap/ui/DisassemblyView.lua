---@brief Disassembly pane, source-synced.
---Opens a vertical split showing the instructions around the current program
---counter and keeps a two-way cursor sync with the source window it was
---launched from (Compiler-Explorer / gdb `layout split` style): moving the
---cursor in the source highlights the matching instruction block here, and
---moving the cursor here jumps the source window to the originating line.
---
---Read-only: instruction-granularity stepping and instruction breakpoints are
---deliberately not handled here.

local manager   = require("ndap.manager")
local config    = require("ndap.config").current
local format    = require("ndap.ui.format")
local ui_util   = require("ndap.util.ui")
local throttle  = require("ndap.util.throttle")

local _au_group_gen

-- Tunables

local _COUNT    = 80 -- fallback instruction count when the window doesn't exist yet
local _ADDR_W   = 18 -- width of the address column

-- Highlight groups. The PC marker and breakpoint signs share ndap's own groups
-- (see `ndap.ui.format`); only the source-block band is this view's own.

local _PC_HL    = format.hl.debug_frame
local _BLOCK_HL = "NdapDisasmBlock"

vim.api.nvim_set_hl(0, _BLOCK_HL, { link = "CursorLine", default = true })


-- Helpers

---Compare two adapter addresses, tolerating differing hex widths/zero-padding.
---@param a string?
---@param b string?
---@return boolean
local function _addr_eq(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local na, nb = tonumber(a), tonumber(b)
    return na ~= nil and na == nb
end

---@param path string?
---@return string?
local function _norm(path)
    if not path or path == "" then return nil end
    return vim.fn.fnamemodify(path, ":p")
end

---Drop sentinel rows the adapter pads a `disassemble` reply with when the range
---overruns disassemblable memory: the spec-sanctioned `presentationHint == "invalid"`,
---plus ad-hoc junk (negative/empty address, empty instruction) that poisons paging.
---@param instrs ndap.dap.proto.DisassembledInstruction[]
---@return ndap.dap.proto.DisassembledInstruction[]
local function _valid_instrs(instrs)
    local out = {} ---@type ndap.dap.proto.DisassembledInstruction[]
    for _, ins in ipairs(instrs) do
        local addr = ins.address
        local n    = addr and tonumber(addr)
        if ins.presentationHint ~= "invalid"
            and addr and addr ~= "" and (n == nil or n >= 0)
            and ins.instruction and ins.instruction ~= "" then
            out[#out + 1] = ins
        end
    end
    return out
end

---First line in a row table whose instruction matches `addr`.
---@param rows table<integer, ndap.DisassemblyView.Row>
---@param addr string?
---@return integer?
local function _row_of(rows, addr)
    if not addr then return end
    for lnum, ins in pairs(rows) do
        if _addr_eq(ins.address, addr) then return lnum end
    end
end

-- Class

---@class ndap.DisassemblyView.SrcRange
---@field first integer  first asm row (1-based) mapped to a source line
---@field last  integer  last asm row mapped to that source line

---Instruction augmented with the resolved/normalised source location.
---@class ndap.DisassemblyView.Row : ndap.dap.proto.DisassembledInstruction
---@field _path?  string  normalised source path
---@field _sline? integer source line

---@class ndap.DisassemblyView
---@field private _bufnr?    integer
---@field private _win?      integer  the asm window
---@field private _src_win?  integer  source window kept in sync
---@field private _sess?     ndap.dap.Session
---@field private _rows      table<integer, ndap.DisassemblyView.Row>  asm line -> instruction
---@field private _by_src    table<string, table<integer, ndap.DisassemblyView.SrcRange>>
---@field private _ns_pc     integer  PC line highlight + sign
---@field private _ns_block  integer  transient source-block highlight
---@field private _ns_bp     integer  instruction-breakpoint signs
---@field private _instrs?   ndap.DisassemblyView.Row[]  current ordered instruction list (paging)
---@field private _pc_ref?   string   instructionReference marked as the PC for the current load
---@field private _paging?   boolean  in-flight paging guard
---@field private _exhausted table<"up"|"down", boolean>  edges with no further instructions to fetch
---@field private _aug?      integer  sync autocmd group; created on open, deleted on close
---@field private _load_seq  integer  identifies the current render; guards page splices
---@field private _syncing   boolean  re-entrancy guard around programmatic moves
---@field private _closing?   boolean  re-entrancy guard around close()
---@field private _src_sync  fun()    throttled source -> asm
---@field private _asm_sync  fun()    throttled asm -> source
local DisassemblyView = {}
DisassemblyView.__index = DisassemblyView

---@return ndap.DisassemblyView
function DisassemblyView.new()
    local self = setmetatable({
        _rows      = {},
        _by_src    = {},
        _ns_pc     = vim.api.nvim_create_namespace("ndap_disasm_pc"),
        _ns_block  = vim.api.nvim_create_namespace("ndap_disasm_block"),
        _ns_bp     = vim.api.nvim_create_namespace("ndap_disasm_bp"),
        _load_seq  = 0,
        _syncing   = false,
        _exhausted = { up = false, down = false },
    }, DisassemblyView)
    self:_init()
    return self
end

---@private
function DisassemblyView:_init()
    self._src_sync = throttle.throttle_wrap(40, function() self:_sync_from_source() end)
    self._asm_sync = throttle.throttle_wrap(40, function() self:_sync_to_source() end)

    manager.on_active_changed:subscribe(function(_, sess) self._sess = sess end)
    manager.on_selection_changed:subscribe(function()
        if self:_is_open() then self:_load(false) end
    end)

    manager.on_session_stopped:subscribe(function(id)
        if id ~= manager.active_id() then return end
        if self:_is_open() then self:_load(false) end
    end)

    -- The PC marker belongs to a pause; drop it once that pause is over, keeping
    -- the pane itself open for post-mortem inspection. A thread starting under a
    -- live breakpoint also reads as "running", so the thread the marker was drawn
    -- for is what decides.
    manager.on_session_updated:subscribe(function(id, info)
        if id ~= manager.active_id() then return end
        if info.state == "terminated" or info.state == "exited" then
            self:_clear_pc()
            return
        end
        if info.is_paused then return end
        local sess   = manager.session()
        local thread = sess and sess:current_thread()
        if thread and thread.status == "stopped" then return end
        self:_clear_pc()
    end)

    manager.on_instruction_breakpoints_changed:subscribe(function(id)
        if id ~= manager.active_id() then return end
        if self:_is_open() then self:_draw_bps() end
    end)

    self._sess = manager.session()
end

---Create the sync autocmd group (and its source-side listener) on first open.
---@private
function DisassemblyView:_ensure_autocmds()
    if self._aug then return end
    _au_group_gen = _au_group_gen and (_au_group_gen + 1) or 1
    self._aug = vim.api.nvim_create_augroup(("ndap_disasm_sync_%d"):format(_au_group_gen), { clear = true })

    -- source -> asm: a global CursorMoved that fires while the cursor is in any window
    -- other than the asm pane. _sync_from_source then decides from _by_src whether that
    -- window shows mapped source, so the bound window is discovered dynamically.
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = self._aug,
        callback = function()
            if self._syncing or not self:_is_open() then return end
            if vim.api.nvim_get_current_win() == self._win then return end
            self._src_sync()
        end,
    })
end

---Delete the sync autocmd group; called whenever the pane closes so the global
---CursorMoved listener does not linger while the pane is hidden.
---@private
function DisassemblyView:_teardown_autocmds()
    if self._aug then
        vim.api.nvim_del_augroup_by_id(self._aug)
        self._aug = nil
    end
end

-- Window / buffer plumbing

---@private
---@return integer
function DisassemblyView:_win_height()
    if self:_is_open() then
        return vim.api.nvim_win_get_height(self._win)
    end
    return _COUNT
end

---Instructions to fetch per load/page. Deliberately larger than the viewport so
---there is always rendered content just beyond the visible area to scroll into
---before the next page is fetched.
---@private
---@return integer
function DisassemblyView:_page_size()
    return self:_win_height() * 2
end

---@private
---@return boolean
function DisassemblyView:_is_open()
    return self._win ~= nil and vim.api.nvim_win_is_valid(self._win)
end

---@private
function DisassemblyView:_ensure_win()
    self:_ensure_autocmds()

    if not (self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr)) then
        -- buffer deleted -> close the window too
        self._bufnr = ui_util.create_scratch_buffer(false, { filetype = "asm" }, function()
            self._bufnr = nil
            self:close()
        end)
        local bufname = "ndap://disassembly"
        local oldbuf = vim.fn.bufnr(bufname)
        if oldbuf > 0 then vim.api.nvim_buf_delete(oldbuf, {}) end
        vim.api.nvim_buf_set_name(self._bufnr, bufname)
        -- identity flag consumers use to recognise the disassembly pane (the
        -- buffer name may be cwd-prefixed, so matching on it is unreliable).
        vim.b[self._bufnr].ndap_disasm = true
        self:_setup_keymaps(self._bufnr)

        -- asm -> source sync + edge paging, bound to the asm buffer.
        vim.api.nvim_create_autocmd("CursorMoved", {
            group    = self._aug,
            buffer   = self._bufnr,
            callback = function()
                self:_maybe_page()
                if self._syncing then return end
                self._asm_sync()
            end,
        })
    end

    if not self:_is_open() then
        -- enter=false: keep focus on the source window; _load() focuses us
        -- explicitly on an interactive open.
        local win                  = ui_util.create_window(self._bufnr, false, {
            split = "left",
            win   = 0,
        }, function()
            -- window closed -> delete the buffer too
            self._win = nil
            self:close()
        end)
        ui_util.win_setlocal(win, "number", false)
        ui_util.win_setlocal(win, "relativenumber", false)
        ui_util.win_setlocal(win, "signcolumn", "yes")
        ui_util.win_setlocal(win, "winfixbuf", true)
        self._win                  = win
    end
end

---@private
---@param lines string[]
function DisassemblyView:_set_lines(lines)
    local buf = self._bufnr
    if not buf then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

-- Loading & rendering

---Fetch and render disassembly for the active frame.
---@private
---@param focus boolean  focus the pane afterwards (only on explicit open)
function DisassemblyView:_load(focus)
    local sess = manager.session()
    if not sess then
        if focus then vim.notify("[dap] no active session", vim.log.levels.WARN) end
        return
    end
    local frame = sess:current_stack_frame()
    local ref   = frame and frame.instructionPointerReference
    if not ref or type(ref) ~= "string" or ref == "" then
        if focus then vim.notify("[dap] no instruction pointer for current frame", vim.log.levels.WARN) end
        return
    end

    -- Fast path: if the new PC is already in the loaded window (the common case
    -- when single-stepping), just move the marker, with no disassemble round-trip.
    if self:_is_open() and self._instrs and #self._instrs > 0 and self:_repoint_pc(ref) then
        if focus then vim.api.nvim_set_current_win(self._win) end
        return
    end

    local count   = self:_page_size()
    local offset  = -math.floor(count / 2)
    -- The reply renders a PC marker and can open the pane, so a stale one would
    -- point at a pause that is over. Dropping it on any context change also settles
    -- two loads racing across a fast step: the superseded one never lands.
    local context = manager.context_id()
    sess:disassemble({ memoryReference = ref, instructionCount = count, instructionOffset = offset },
        function(instrs, err)
            vim.schedule(function()
                if manager.context_id() ~= context then return end
                if err or not instrs then
                    vim.notify("[dap] disassemble failed: " .. (err or "no instructions"), vim.log.levels.WARN)
                    return
                end
                instrs = _valid_instrs(instrs)
                if #instrs == 0 then
                    if focus then vim.notify("[dap] no instructions to disassemble", vim.log.levels.WARN) end
                    return
                end
                self:_ensure_win()
                self:_render(instrs, ref, true)
                if focus and self:_is_open() then
                    vim.api.nvim_set_current_win(self._win)
                end
            end)
        end)
end

---Move the PC marker to `ref` when it already lives in the loaded window, recentering
---the cursor on it exactly as a fresh render would. Returns false (no state touched)
---when the address is not loaded, so the caller falls back to a full disassemble.
---@private
---@param ref string
---@return boolean handled
function DisassemblyView:_repoint_pc(ref)
    local row = _row_of(self._rows, ref)
    if not row then return false end

    self._pc_ref = ref
    self:_draw_pc(row)
    if self:_is_open() then
        pcall(vim.api.nvim_win_set_cursor, self._win, { row, 0 })
    end
    return true
end

---Render an instruction list into buffer lines and the accompanying lookup
---tables, without touching the buffer or any state. Pure: callers decide how to
---apply the result (full replace for loads, incremental splice for paging).
---@private
---@param instrs ndap.DisassemblyView.Row[]
---@param pc_ref string?
---@return string[] lines
---@return table<integer, ndap.DisassemblyView.Row> rows
---@return table<string, table<integer, ndap.DisassemblyView.SrcRange>> by_src
---@return integer? pc_row
function DisassemblyView:_build(instrs, pc_ref)
    local lines  = {} ---@type string[]
    local rows   = {} ---@type table<integer, ndap.DisassemblyView.Row>
    local by_src = {} ---@type table<string, table<integer, ndap.DisassemblyView.SrcRange>>
    local pc_row = nil ---@type integer?

    -- one buffer line per instruction (no symbol-header lines), so rows and
    -- lines stay 1:1; the paging splice depends on that invariant.
    for _, ins in ipairs(instrs) do
        local addr = ins.address or ""
        lines[#lines + 1] = ("%-" .. _ADDR_W .. "s %s"):format(addr, ins.instruction or "")
        local lnum = #lines

        ---@cast ins ndap.DisassemblyView.Row
        rows[lnum] = ins
        if _addr_eq(addr, pc_ref) then pc_row = lnum end

        local path  = ins.location and _norm(ins.location.path)
        local sline = ins.line
        if path and sline then
            ins._path, ins._sline = path, sline
            by_src[path] = by_src[path] or {}
            local e = by_src[path][sline]
            if e then
                e.first = math.min(e.first, lnum)
                e.last  = math.max(e.last, lnum)
            else
                by_src[path][sline] = { first = lnum, last = lnum }
            end
        end
    end

    return lines, rows, by_src, pc_row
end

---Render an instruction list into the buffer, replacing its entire contents.
---Used for fresh loads; paging edits the buffer incrementally instead.
---@private
---@param instrs ndap.DisassemblyView.Row[]
---@param pc_ref string?
---@param recenter boolean?  center the cursor on the PC row (fresh loads only)
function DisassemblyView:_render(instrs, pc_ref, recenter)
    local lines, rows, by_src, pc_row = self:_build(instrs, pc_ref)

    self:_set_lines(lines)
    self._rows      = rows
    self._by_src    = by_src
    self._instrs    = instrs
    self._pc_ref    = pc_ref
    self._exhausted = { up = false, down = false }
    self._paging    = false -- a fresh load supersedes any page still in flight
    self._load_seq  = self._load_seq + 1

    self:_draw_pc(pc_row)
    self:_draw_bps()

    if recenter and pc_row and self:_is_open() then
        pcall(vim.api.nvim_win_set_cursor, self._win, { pc_row, 0 })
    end
end

-- PC marker

---@private
---@param pc_row integer?
function DisassemblyView:_draw_pc(pc_row)
    self:_clear_pc()
    if not pc_row then return end
    vim.api.nvim_buf_set_extmark(self._bufnr, self._ns_pc, pc_row - 1, 0, {
        line_hl_group = _PC_HL,
        sign_text     = config.symbols.debug_frame,
        sign_hl_group = _PC_HL,
        priority      = 100,
        hl_mode       = "blend",
    })
end

---@private
function DisassemblyView:_clear_pc()
    if self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr) then
        vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns_pc, 0, -1)
    end
end

---@private
function DisassemblyView:_clear_block()
    if self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr) then
        vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns_block, 0, -1)
    end
end

-- Instruction breakpoints

---Re-draw breakpoint signs from the active session's instruction-breakpoint set.
---@private
function DisassemblyView:_draw_bps()
    if not (self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr)) then return end
    vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns_bp, 0, -1)

    local sess = self._sess
    if not sess then return end
    local bps = sess:instruction_breakpoints()
    if not bps or vim.tbl_isempty(bps) then return end

    for lnum, ins in pairs(self._rows) do
        local st = ins.address and bps[ins.address]
        if st then
            -- Instruction breakpoints carry no condition; only the verified flag
            -- picks the glyph and its highlight.
            local sign, hl = format.breakpoint_symbol({ verified = st.verified == true })
            vim.api.nvim_buf_set_extmark(self._bufnr, self._ns_bp, lnum - 1, 0, {
                sign_text = sign, sign_hl_group = hl,
            })
        end
    end
end

---Toggle an instruction breakpoint on the instruction under the cursor.
---@private
function DisassemblyView:_toggle_bp_at_cursor()
    if not self:_is_open() then return end
    local ins = self._rows[vim.api.nvim_win_get_cursor(self._win)[1]]
    if not ins or not ins.address then return end
    local sess = self._sess
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN)
        return
    end
    sess:toggle_instruction_breakpoint(ins.address)
end

-- Instruction details (hover)

---Show the adapter-reported metadata for the instruction under the cursor in an
---LSP-style floating preview: address, raw bytes, symbol, source mapping and
---breakpoint state. A second press focuses the float; moving the cursor dismisses it.
---@private
function DisassemblyView:_hover()
    if not self:_is_open() then return end
    local ins = self._rows[vim.api.nvim_win_get_cursor(self._win)[1]]
    if not ins then return end

    local lines = {} ---@type string[]
    local function add(label, val)
        if val and val ~= "" then lines[#lines + 1] = ("- **%s** %s"):format(label, val) end
    end

    lines[#lines + 1] = ("### `%s`"):format(ins.address or "?")
    lines[#lines + 1] = ""
    add("Instruction", ins.instruction and ("`%s`"):format(ins.instruction))
    add("Bytes", ins.instructionBytes and ("`%s`"):format(ins.instructionBytes))
    add("Symbol", ins.symbol and ("`%s`"):format(ins.symbol))

    local path = ins._path or (ins.location and ins.location.path)
    if path and ins.line then
        local loc = ("%s:%d"):format(vim.fn.fnamemodify(path, ":~:."), ins.line)
        if ins.column then loc = ("%s:%d"):format(loc, ins.column) end
        if ins.endLine and ins.endLine ~= ins.line then loc = ("%s–%d"):format(loc, ins.endLine) end
        add("Source", loc)
    end

    local bps = self._sess and self._sess:instruction_breakpoints()
    local bp  = bps and ins.address and bps[ins.address]
    if bp then add("Breakpoint", bp.verified and "verified" or "pending") end

    vim.lsp.util.open_floating_preview(lines, "markdown", {
        border    = "rounded",
        focusable = true,
        focus     = false,
        focus_id  = "ndap_asm_hover",
        max_width = 80,
        wrap      = true,
    })
end

-- Source navigation

---Open the source line the instruction under the cursor maps to, reusing a window
---already showing that file (or the nearest regular window). `focus` moves the
---cursor into it; without it the pane keeps focus. No-op without a source mapping.
---@private
---@param focus boolean
function DisassemblyView:_open_source_at_cursor(focus)
    if not self:_is_open() then return end
    local ins = self._rows[vim.api.nvim_win_get_cursor(self._win)[1]]
    if not ins then return end

    local path = ins._path or (ins.location and _norm(ins.location.path))
    local line = ins._sline or ins.line
    if not path then
        return
    end

    local col = ins.column and (ins.column - 1) or nil
    ui_util.smart_open_file(path, line, col, focus)
end

-- Paging

---Fetch more instructions when the cursor reaches an edge of the loaded window: the
---first line pages up, the last pages down, jumps included. No infinite retry: an
---empty page marks the edge `_exhausted` until the cursor steps off it and back.
---@private
function DisassemblyView:_maybe_page()
    if not self:_is_open() then return end
    if self._paging or self._syncing then return end
    if not self._instrs or #self._instrs == 0 then return end

    local row   = vim.api.nvim_win_get_cursor(self._win)[1]
    local total = vim.api.nvim_buf_line_count(self._bufnr)

    -- Re-arm an edge once the cursor steps off it. `_exhausted` means "no more from
    -- this position", not "never again": a transient empty reply must not kill paging
    -- for good. While the cursor sits pinned on a real boundary the flag survives.
    if row > 1 then self._exhausted.up = false end
    if row < total then self._exhausted.down = false end

    if row <= 1 then
        self:_page("up")
    elseif row >= total then
        self:_page("down")
    end
end

---Slide the loaded instruction window in `dir`: fetch a page just beyond the
---current edge, then hand off to _apply_page to splice it in.
---@private
---@param dir "up"|"down"
function DisassemblyView:_page(dir)
    local sess   = self._sess
    local instrs = self._instrs
    if self._paging or not sess or not instrs or #instrs == 0 then return end
    if self._exhausted[dir] then return end -- adapter already reported no more instructions this way
    if not self:_is_open() then return end

    local edge      = dir == "down" and instrs[#instrs] or instrs[1]
    local edge_addr = edge and edge.address
    if not edge_addr then return end

    -- Anchor on the instruction at (or, when sitting on a symbol header, just
    -- below) the cursor. The splice leaves this instruction's line untouched, so
    -- Neovim's own cursor/scroll handling holds the view exactly where it is.
    local cur_line    = vim.api.nvim_win_get_cursor(self._win)[1]
    local anchor      = self._rows[cur_line] or self._rows[cur_line + 1]
    local anchor_addr = anchor and anchor.address
    if not anchor_addr then return end

    self._paging = true
    local page   = self:_page_size()
    local offset = dir == "down" and 1 or -page

    -- A page splices into the buffer it was measured against, so what invalidates
    -- it is a fresh render replacing the rows (or the session under them), not the
    -- debug context: instructions are static memory, and paging through the pane
    -- stays valid while the program runs.
    local load_seq = self._load_seq
    sess:disassemble({ memoryReference = edge_addr, instructionCount = page, instructionOffset = offset },
        function(new, err)
            if load_seq ~= self._load_seq or sess ~= self._sess then return end
            vim.schedule(function()
                if load_seq ~= self._load_seq or sess ~= self._sess then return end
                self._paging = false
                if not self:_is_open() then return end
                -- Past the edge of disassemblable memory the adapter returns nothing,
                -- fails the request, or pads with sentinels that _valid_instrs strips.
                -- Mark the edge exhausted and stop probing; _maybe_page re-arms it.
                if err or not new then
                    self._exhausted[dir] = true
                    return
                end
                new = _valid_instrs(new)
                if #new == 0 then
                    self._exhausted[dir] = true
                    return
                end
                self:_apply_page(dir, new, page, anchor_addr)
            end)
        end)
end

---Splice a freshly fetched page into the buffer with two localised edits: grow one
---end, trim the other, leaving the anchor instruction's line byte-identical. Ranges
---come from line counts and `self._rows`; the cursor is never set explicitly.
---@private
---@param dir "up"|"down"
---@param new ndap.DisassemblyView.Row[]
---@param page integer
---@param anchor_addr string
function DisassemblyView:_apply_page(dir, new, page, anchor_addr)
    local buf = self._bufnr
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

    local instrs = self._instrs or {}
    local seen   = {} ---@type table<string, boolean>
    for _, ins in ipairs(instrs) do
        if ins.address then seen[ins.address] = true end
    end

    local cap = page * 2 -- keep at most two pages' worth of instructions loaded
    local merged ---@type ndap.DisassemblyView.Row[]

    if dir == "down" then
        local added = 0
        for _, ins in ipairs(new) do
            if ins.address and not seen[ins.address] then
                instrs[#instrs + 1] = ins
                seen[ins.address]   = true
                added               = added + 1
            end
        end
        if added == 0 then
            self._exhausted.down = true
            return
        end
        -- bluntly crop the front to the cap; the new top may start mid-symbol,
        -- which is fine since instructions render one-per-line with no headers.
        if #instrs > cap then
            merged = vim.list_slice(instrs, #instrs - cap + 1, #instrs)
        else
            merged = instrs
        end
    else
        local head = {} ---@type ndap.DisassemblyView.Row[]
        for _, ins in ipairs(new) do
            if ins.address and not seen[ins.address] then
                head[#head + 1]   = ins
                seen[ins.address] = true
            end
        end
        if #head == 0 then
            self._exhausted.up = true
            return
        end
        merged = head
        for _, ins in ipairs(instrs) do merged[#merged + 1] = ins end
        if #merged > cap then merged = vim.list_slice(merged, 1, cap) end
    end

    local new_lines, rows, by_src, pc_row = self:_build(merged, self._pc_ref)
    local oa                              = _row_of(self._rows, anchor_addr)
    local na                              = _row_of(rows, anchor_addr)

    self._syncing                         = true
    vim.bo[buf].modifiable                = true
    if oa and na then
        local o = vim.api.nvim_buf_line_count(buf)
        local n = #new_lines
        if dir == "down" then
            -- append below, then trim the top (oa-na lines). Both edits sit
            -- outside the anchor's screen region, so Neovim keeps the cursor on
            -- its instruction and the view steady on its own.
            vim.api.nvim_buf_set_lines(buf, o, o, false,
                vim.list_slice(new_lines, na + (o - oa) + 1, n))
            if oa > na then
                vim.api.nvim_buf_set_lines(buf, 0, oa - na, false, {})
            end
        else
            -- trim the bottom (old coords) first, then prepend at the top
            if o > oa + (n - na) then
                vim.api.nvim_buf_set_lines(buf, oa + (n - na), o, false, {})
            end
            vim.api.nvim_buf_set_lines(buf, 0, 0, false,
                vim.list_slice(new_lines, 1, na - oa))
        end
    else
        -- anchor vanished (shouldn't happen): fall back to a full replace
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    end
    vim.bo[buf].modifiable = false
    vim.schedule(function() self._syncing = false end)

    self._rows                                        = rows
    self._by_src                                      = by_src
    self._instrs                                      = merged
    -- the window slid, so the trimmed-away edge is fetchable again
    self._exhausted[dir == "down" and "up" or "down"] = false

    self:_draw_pc(pc_row)
    self:_draw_bps()

    -- after the splice has redrawn, pull content into any blank below EOF.
    vim.schedule(function()
        if not self:_is_open() then return end
        ui_util.fill_viewport(self._win)
    end)
end

-- Sync

---Move/highlight the asm pane to match the cursor in the active source window.
---The source window is taken to be whatever (non-asm) window currently holds the
---cursor; we only adopt it as `_src_win` once it proves to show mapped source.
---@private
function DisassemblyView:_sync_from_source()
    if not self:_is_open() then return end
    local win = vim.api.nvim_get_current_win()
    if win == self._win or not vim.api.nvim_win_is_valid(win) then return end

    local path = _norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
    local line = vim.api.nvim_win_get_cursor(win)[1]

    self:_clear_block()
    local entry = path and self._by_src[path] and self._by_src[path][line]
    if not entry then return end

    self._src_win = win -- remember it for the asm -> source direction

    for l = entry.first, entry.last do
        vim.api.nvim_buf_set_extmark(self._bufnr, self._ns_block, l - 1, 0, { line_hl_group = _BLOCK_HL, priority = 5000 })
    end

    self._syncing = true
    pcall(vim.api.nvim_win_set_cursor, self._win, { entry.first, 0 })
    vim.schedule(function() self._syncing = false end)
end

---Move the source window to match the asm cursor.
---@private
function DisassemblyView:_sync_to_source()
    if not self:_is_open() then return end
    local ins = self._rows[vim.api.nvim_win_get_cursor(self._win)[1]]
    if not ins or not ins._path then return end

    local win = self._src_win
    if not (win and vim.api.nvim_win_is_valid(win)) then return end

    self._syncing = true
    local curpath = _norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
    if curpath == ins._path then
        pcall(vim.api.nvim_win_set_cursor, win, { ins._sline, 0 })
    end
    vim.schedule(function() self._syncing = false end)
end

-- Keymaps

---@private
---@param bufnr integer
function DisassemblyView:_setup_keymaps(bufnr)
    local function map(lhs, rhs, desc)
        vim.keymap.set("n", lhs, rhs, { buffer = bufnr, desc = desc })
    end

    map("<CR>", function() self:_open_source_at_cursor(true) end, "Open source line")
    map("o", function() self:_open_source_at_cursor(false) end, "Open source line, keeping focus")
    map("K", function() self:_hover() end, "Instruction reference")
end

-- Public API

---Open the disassembly pane for the active frame (or focus + refresh if open).
function DisassemblyView:open()
    if not self:_is_open() then
        self._src_win = vim.api.nvim_get_current_win()
    end
    self:_load(true)
end

---Close the disassembly pane: tears down the window, buffer and autocmds
---together. Re-entrant-safe so it can be driven from either the WinClosed or
---the BufDelete/BufWipeout callback (window and buffer co-terminate).
function DisassemblyView:close()
    if self._closing then return end
    self._closing = true

    self:_clear_block()
    self:_teardown_autocmds()

    local win, buf = self._win, self._bufnr
    self._win, self._bufnr = nil, nil

    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end

    self._closing = false
end

---Toggle an instruction breakpoint on the instruction under the cursor.

function DisassemblyView:toggle_bp_at_cursor()
    self:_toggle_bp_at_cursor()
end

return DisassemblyView
