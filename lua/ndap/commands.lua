---@brief User-facing command surface: the `breakpoint`, `debug`, `view` and
---`panel` tables reached through `:Ndap …`. These sit on top of `manager`
---(active session + control primitives) and own all the user interaction:
---pickers, prompts, notifications and cursor handling.

local select        = require("ndap.util.select")
local inputwin      = require("ndap.util.inputwin")
local manager       = require("ndap.manager")
local format        = require("ndap.ui.format")
local exception_info = require("ndap.ui.exception_info")

local M             = {}

-- Everything reaching the DAP layer goes through `manager` (the programmatic API);
-- this module owns only the user interaction (cursor reads, prompts, pickers and
-- notifications), resolving those into the concrete details `manager` takes.

-- Module state

---Cursor-follow records, keyed by breakpoint internal_id. Armed when the user adds
---a source breakpoint while a session is live; consumed one-shot once the adapter
---reports where it bound it, and only while the user is still parked there.
---@class ndap.commands.PendingFollow
---@field win  integer  window the breakpoint was added from
---@field file string   source file that window must still show
---@field line integer  line it was added at; the cursor must still sit here
---@type table<integer, ndap.commands.PendingFollow>
local _pending_follow = {}

-- A follow is keyed to the active session's binding; once the active session
-- changes any armed follow is stale, so drop them all rather than risk acting on
-- the wrong session's resolved line.
manager.on_active_changed:subscribe(function() _pending_follow = {} end)

-- Consume a follow on the adapter's first report: move the cursor to the bound
-- line, but only while the user still sits where they added it.
manager.on_breakpoint_updated:subscribe(function(_, bp, status)
    local rec = _pending_follow[bp.internal_id]
    if not rec then return end
    _pending_follow[bp.internal_id] = nil

    -- Same window, file and line as when it was added, or they have moved on.
    if not vim.api.nvim_win_is_valid(rec.win) then return end
    if vim.api.nvim_get_current_win() ~= rec.win then return end
    if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(rec.win)) ~= rec.file then return end
    if vim.api.nvim_win_get_cursor(rec.win)[1] ~= rec.line then return end

    local target = status and status.line
    if not target or target == rec.line then return end
    local col = vim.api.nvim_win_get_cursor(rec.win)[2]
    vim.api.nvim_win_set_cursor(rec.win, { target, col })
end)

---The two view singletons, created on first access. They live here rather than
---in `init` so the command surface never reaches back into the entry point;
---`init` keeps guarded delegates for the public API.
---@type ndap.DebugView?
local _debug_view
---@type ndap.DisassemblyView?
local _disassembly_view

-- Helpers

---@return string?
---@return integer
local function _cursor_location()
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype ~= "" then
        vim.notify("[dap] current buffer is not a regular buffer", vim.log.levels.WARN)
        return nil, 0
    end
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then
        vim.notify("[dap] current buffer has no file path", vim.log.levels.WARN)
        return nil, 0
    end
    return file, vim.api.nvim_win_get_cursor(0)[1]
end

---Run `fn(sess)` on the active session, but only if it advertises `capability`.
---Shows an error when the adapter lacks the capability, a warning when there is
---no active session. Use for any command gated on a DAP capability.
---@param capability string  e.g. "supportsRestartFrame"
---@param label      string  human-readable command name for the error message
---@param fn         fun(sess: ndap.dap.Session)
local function _with_capability(capability, label, fn)
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    if not sess:capable(capability) then
        vim.notify("[dap] adapter does not support " .. label, vim.log.levels.ERROR)
        return
    end
    fn(sess)
end

-- Live sessions now push breakpoint changes themselves by subscribing to
-- breakpoints.on_change (see session.lua), so the commands below only mutate the
-- registry, so no explicit per-command sync is needed.

-- Breakpoints

M.breakpoint = {}

---Where a source breakpoint is shown: the adapter-resolved position if the
---session has bound it elsewhere, else the stored one.
---@param bp ndap.dap.SourceBreakpoint
---@return integer  line   1-based
---@return integer? column 1-based (nil = whole-line breakpoint)
local function _shown_pos(bp)
    local st = manager.bp_status(bp.internal_id)
    return (st and st.line) or bp.line, (st and st.column) or bp.column
end

---@param bp ndap.dap.SourceBreakpoint
---@return integer
local function _shown_line(bp)
    local line = _shown_pos(bp)
    return line
end

---@param bp ndap.dap.SourceBreakpoint
---@return integer?
local function _shown_column(bp)
    local _, column = _shown_pos(bp)
    return column
end

---Find an existing source breakpoint in `file` whose displayed line (adapter-resolved
---if the session moved it, else stored) is `row`, returning its stored line: the
---registry key. A relocated breakpoint has no sign there, so toggling acts on what shows.
---@param file string
---@param row  integer
---@return integer?
local function _existing_bp_line(file, row)
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.for_source(file)) do
        -- Column breakpoints are managed by their own command, not the line toggle.
        if bp.column == nil and _shown_line(bp) == row then return bp.line end
    end
end

---Find a breakpoint stored at `row` that the adapter has relocated elsewhere.
---Returns the line it is now shown at, or nil.
---@param file string
---@param row  integer
---@return integer?
local function _moved_bp_target(file, row)
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.for_source(file)) do
        if bp.column == nil and bp.line == row then
            local shown = _shown_line(bp)
            if shown ~= bp.line then return shown end
        end
    end
end

function M.breakpoint.toggle()
    local file, row = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
    -- Toggling off matches the line you see, which may be the adapter-resolved
    -- line rather than the stored one.
    local existing = _existing_bp_line(file, row)
    if existing then
        bps.remove(file, existing)
    else
        -- This line is the stored origin of a breakpoint the adapter relocated
        -- elsewhere; adding here would just be relocated to the same spot, so
        -- jump to where it is actually shown instead of toggling.
        local moved_to = _moved_bp_target(file, row)
        if moved_to then
            local col = vim.api.nvim_win_get_cursor(0)[2]
            vim.api.nvim_win_set_cursor(0, { moved_to, col })
            return
        end
        -- The registry change pushes to the adapter on its own; arm the follow so
        -- the cursor tracks the breakpoint if the adapter relocates it.
        local bp = bps.add(file, row)
        if bp and manager.session() then
            _pending_follow[bp.internal_id] = {
                win  = vim.api.nvim_get_current_win(),
                file = file,
                line = row,
            }
        end
    end
end

---Snap a 1-based column to the start of the word under it.
---Returns col unchanged if the character is not a word character.
---@param line string
---@param col  integer  1-based
---@return integer
local function _word_start(line, col)
    if not line:sub(col, col):match("[%w_]") then return col end
    local i = col
    while i > 1 and line:sub(i - 1, i - 1):match("[%w_]") do
        i = i - 1
    end
    return i
end

---A breakpoint's registry key: what `breakpoints.patch`/`remove` identify it by.
---@class ndap.commands.BpKey
---@field line   integer
---@field column integer?

---Every breakpoint in `file` shown on `row` (the adapter-resolved line when the
---session moved it, else the stored one), line breakpoint first, then by column.
---@param file string
---@param row  integer
---@return ndap.dap.SourceBreakpoint[]
local function _bps_at_row(file, row)
    local out = {}
    for _, bp in ipairs(manager.breakpoints.for_source(file)) do
        if _shown_line(bp) == row then out[#out + 1] = bp end
    end
    table.sort(out, function(a, b) return (_shown_column(a) or 0) < (_shown_column(b) or 0) end)
    return out
end

---Resolve which breakpoint on the cursor row a command acts on. A column
---breakpoint under the cursor always wins; otherwise the line breakpoint is
---assumed, unless `opts.ask` (for destructive commands, where guessing costs
---the user a breakpoint), which puts every candidate to a picker instead.
---`cb(nil)` when the row carries none, and cb is not called at all if the picker
---is dismissed.
---@param file string
---@param row  integer
---@param opts { ask?: boolean }?
---@param cb   fun(key: ndap.commands.BpKey?, bp: ndap.dap.SourceBreakpoint?)
local function _resolve_target(file, row, opts, cb)
    local cands = _bps_at_row(file, row)
    local function key(bp) return { line = bp.line, column = bp.column }, bp end
    if #cands == 0 then return cb(nil, nil) end
    if #cands == 1 then return cb(key(cands[1])) end
    local cursor_col = vim.api.nvim_win_get_cursor(0)[2] + 1
    for _, bp in ipairs(cands) do
        -- The shown column, not the stored one: the adapter may have moved it.
        if _shown_column(bp) == cursor_col then return cb(key(bp)) end
    end
    if not (opts and opts.ask) then
        for _, bp in ipairs(cands) do
            if bp.column == nil then return cb(key(bp)) end
        end
    end
    select.open({
        prompt = "Breakpoint on line " .. row,
        items  = vim.tbl_map(function(bp)
            local line, column = _shown_pos(bp)
            local chunks       = { { tostring(line), "Number" } }
            if column then
                chunks[#chunks + 1] = { ":" .. column, "Number" }
            else
                chunks[#chunks + 1] = { "  (whole line)", "Comment" }
            end
            if bp.condition then chunks[#chunks + 1] = { "  if: " .. bp.condition, "Comment" } end
            if bp.log_message then chunks[#chunks + 1] = { "  log: " .. bp.log_message, "Comment" } end
            return { chunks = chunks, data = bp }
        end, cands),
        sort_by_score = false,
    }, function(bp)
        if bp then cb(key(bp)) end
    end)
end

---Toggle a column breakpoint at the cursor, at the start of the word under it.
---A breakpoint shown in that word is removed; otherwise one is created. The
---column counterpart of the plain line toggle.
function M.breakpoint.column()
    local file, row = _cursor_location()
    if not file then return end
    local bufnr    = vim.api.nvim_get_current_buf()
    local linetext = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local col      = _word_start(linetext, vim.api.nvim_win_get_cursor(0)[2] + 1)
    local bps      = manager.breakpoints
    for _, bp in ipairs(_bps_at_row(file, row)) do
        -- Match where it is shown, not where it was asked for: the adapter may
        -- have bound it elsewhere, leaving the stored column unreachable.
        local shown = _shown_column(bp)
        if shown and _word_start(linetext, shown) == col then
            bps.remove(file, bp.line, bp.column)
            return
        end
    end
    bps.patch(file, row, { column = col })
end

function M.breakpoint.remove()
    local file, row = _cursor_location()
    if not file then return end
    -- Removal is destructive, so a line carrying both a line and column
    -- breakpoints asks rather than assuming the line one.
    _resolve_target(file, row, { ask = true }, function(key)
        if key then manager.breakpoints.remove(file, key.line, key.column) end
    end)
end

function M.breakpoint.clear_file()
    local file, _ = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.for_source(file)) do bps.remove(file, bp.line, bp.column) end
end

---Removes every source, function and exception-name breakpoint. Exception
---filters are adapter-supplied rows, so they are disabled rather than removed.
function M.breakpoint.clear_all()
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.all()) do bps.remove(bp.source, bp.line, bp.column) end
    for _, bp in ipairs(bps.function_breakpoints()) do bps.remove_function(bp.name) end
    for _, bp in ipairs(bps.exception_name_breakpoints()) do bps.remove_exception_name(bp.name) end
    for _, bp in ipairs(bps.exception_breakpoints()) do bps.set_exception_enabled(bp.filter, false) end
end

function M.breakpoint.clear_fn()
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.function_breakpoints()) do bps.remove_function(bp.name) end
end

---Set the disabled flag on the breakpoint the cursor resolves to.
---@param disabled boolean?  nil flips the current state
local function _set_disabled(disabled)
    local file, row = _cursor_location()
    if not file then return end
    _resolve_target(file, row, nil, function(key, bp)
        if not key then
            vim.notify("[dap] no breakpoint at current line", vim.log.levels.WARN); return
        end
        local want = disabled
        if want == nil then want = not bp.disabled end
        manager.breakpoints.patch(file, key.line, { column = key.column, disabled = want })
    end)
end

function M.breakpoint.enable()
    _set_disabled(false)
end

function M.breakpoint.disable()
    _set_disabled(true)
end

---Toggle the enabled/disabled state of the breakpoint at the current line.
function M.breakpoint.toggle_enabled()
    _set_disabled(nil)
end

function M.breakpoint.enable_all()
    manager.breakpoints.enable_all()
end

function M.breakpoint.disable_all()
    manager.breakpoints.disable_all()
end

function M.breakpoint.condition()
    local file, row = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
    _resolve_target(file, row, nil, function(key, bp)
        key = key or { line = row }
        inputwin.open({ prompt = "Condition (empty to clear): ", default = bp and bp.condition or "" },
            function(cond)
                if cond == nil then return end
                inputwin.open({ prompt = "Hit condition (empty to clear): ", default = bp and bp.hit_condition or "" },
                    function(hit)
                        if hit == nil then return end
                        bps.patch(file, key.line,
                            { column = key.column, condition = cond, hit_condition = hit })
                    end)
            end)
    end)
end

function M.breakpoint.logpoint()
    local file, row = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
    _resolve_target(file, row, nil, function(key, bp)
        key = key or { line = row }
        inputwin.open({ prompt = "Log message (empty to clear): ", default = bp and bp.log_message or "" },
            function(input)
                if input == nil then return end
                bps.patch(file, key.line, { column = key.column, log_message = input })
            end)
    end)
end

---Toggle a function breakpoint for `name`; prompted when omitted or empty.
---@param name? string  function name
function M.breakpoint.fn(name)
    local bps = manager.breakpoints
    ---@param n string  function name to add or remove
    local function _toggle(n)
        local found = false
        for _, bp in ipairs(bps.function_breakpoints()) do
            if bp.name == n then
                found = true; break
            end
        end
        if found then bps.remove_function(n) else bps.add_function(n) end
    end
    if name and name ~= "" then
        _toggle(name)
    else
        vim.ui.input({ prompt = "Function name: " }, function(input)
            if input and input ~= "" then _toggle(input) end
        end)
    end
end

function M.breakpoint.exception_filter()
    local bps = manager.breakpoints
    local all = bps.exception_breakpoints()
    if #all == 0 then
        vim.notify("[dap] no exception filters available (start a session first)", vim.log.levels.WARN)
        return
    end
    select.open({
        prompt = "Toggle exception breakpoint",
        items  = vim.tbl_map(function(bp)
            return {
                chunks = {
                    { bp.disabled and "○ " or "● ", bp.disabled and "NonText" or "Special" },
                    { bp.label },
                },
                data   = bp,
            }
        end, all),
    }, function(bp)
        if not bp then return end
        bps.set_exception_enabled(bp.filter, bp.disabled)
    end)
end

---@param name?       string
---@param break_mode? string
function M.breakpoint.exception_type(name, break_mode)
    local bps    = manager.breakpoints
    local _modes = { "always", "unhandled", "userUnhandled", "never" }
    ---@param n    string   exception name to add or remove
    ---@param mode string?  break mode; nil leaves the adapter's default
    local function _toggle(n, mode)
        local result = bps.toggle_exception_name(n, mode)
        vim.notify(
            result
            and ("[dap] exception breakpoint added: " .. n .. " (" .. result.break_mode .. ")")
            or ("[dap] exception breakpoint removed: " .. n),
            vim.log.levels.INFO)
    end
    ---@param n string  exception name to pick a break mode for
    local function _pick_mode(n)
        select.open({ prompt = "Break mode for " .. n .. ": ", items = _modes }, function(mode)
            if mode then _toggle(n, mode) end
        end)
    end
    if name and name ~= "" then
        local existing
        for _, bp in ipairs(bps.exception_name_breakpoints()) do
            if bp.name == name then
                existing = bp; break
            end
        end
        if existing then
            _toggle(name)
        elseif break_mode and break_mode ~= "" then
            _toggle(name, break_mode)
        else
            _pick_mode(name)
        end
    else
        vim.ui.input({ prompt = "Exception type: " }, function(input)
            if not input or input == "" then return end
            _pick_mode(input)
        end)
    end
end

function M.breakpoint.list()
    local bps      = manager.breakpoints
    local cur_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
    local cur_line = vim.api.nvim_win_get_cursor(0)[1]
    local initial ---@type integer?
    local items    = {}
    local all      = bps.all()
    -- The registry keeps insertion order; the list reads as a file index.
    table.sort(all, function(a, b)
        if a.source ~= b.source then return a.source < b.source end
        if a.line ~= b.line then return a.line < b.line end
        return (a.column or 0) < (b.column or 0)
    end)
    for i, bp in ipairs(all) do
        ---@cast bp ndap.dap.SourceBreakpoint
        local st            = manager.bp_status(bp.internal_id)
        local icon, icon_hl = format.breakpoint_symbol({
            kind          = "source",
            disabled      = bp.disabled,
            verified      = st and st.verified,
            condition     = bp.condition,
            hit_condition = bp.hit_condition,
            log_message   = bp.log_message,
        }, true)
        local chunks = { { icon .. " ", icon_hl } }
        chunks[#chunks + 1] = { vim.fn.fnamemodify(bp.source, ":~:."), nil }
        chunks[#chunks + 1] = { ":" .. bp.line .. (bp.column and (":" .. bp.column) or ""), nil }
        -- Condition and log message ride on the same line, after the location.
        local detail = {}
        if bp.condition then detail[#detail + 1] = "• if: " .. bp.condition end
        if bp.hit_condition then detail[#detail + 1] = "• hit: " .. bp.hit_condition end
        if bp.log_message then detail[#detail + 1] = "• log: " .. bp.log_message end
        if #detail > 0 then chunks[#chunks + 1] = { "  " .. table.concat(detail, "  "), "Comment" } end
        if not initial and bp.line == cur_line and vim.fn.fnamemodify(bp.source, ":p") == cur_path then
            initial = i
        end
        items[i] = {
            chunks = chunks,
            data   = { filepath = bp.source, lnum = bp.line, bp = bp },
        }
    end
    if #items == 0 then
        vim.notify("[dap] no breakpoints", vim.log.levels.INFO); return
    end
    select.open({
        prompt         = "Breakpoints",
        enable_preview = true,
        items          = items,
        initial        = initial,
        -- The list reads as a file index; ranking by score would scramble the
        -- lines of a file the moment you filter by its name.
        sort_by_score  = false,
    }, function(data)
        if not data then return end
        require("ndap.util.ui").smart_open_file(data.bp.source, data.bp.line)
    end)
end

-- Data breakpoints (watchpoints)

---Resolve `name` against the active session and either add a data breakpoint
---(prompting for an access type when several are offered) or, if one already
---exists for the resolved dataId, remove it.
---@param sess ndap.dap.Session
---@param name string
---@param variables_reference integer?
local function _toggle_data_bp(sess, name, variables_reference)
    sess:data_breakpoint_info({ name = name, variablesReference = variables_reference }, function(body, err)
        if err or not body or not body.dataId then
            local why = err or (body and body.description) or "not available"
            vim.notify("[dap] cannot watch '" .. name .. "': " .. why, vim.log.levels.WARN)
            return
        end
        for _, bp in ipairs(sess:data_breakpoints()) do
            if bp.data_id == body.dataId then
                sess:remove_data_breakpoint(body.dataId)
                vim.notify("[dap] data breakpoint removed: " .. name, vim.log.levels.INFO)
                return
            end
        end
        local function add(access)
            sess:add_data_breakpoint({ data_id = body.dataId, name = name, access_type = access })
            vim.notify("[dap] data breakpoint set: " .. name
                .. (access and (" (" .. access .. ")") or ""), vim.log.levels.INFO)
        end
        local types = body.accessTypes or {}
        if #types > 1 then
            select.open({ prompt = "Access type for " .. name .. ": ", items = types }, function(t)
                if t then add(t) end
            end)
        else
            add(types[1])
        end
    end)
end

---Set or toggle a data breakpoint (watchpoint) on a variable or expression.
---Requires a stopped session whose adapter advertises supportsDataBreakpoints.
---@param name? string  defaults to the word under the cursor (prompted)
function M.breakpoint.data(name)
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    if not sess:capable("supportsDataBreakpoints") then
        vim.notify("[dap] adapter does not support data breakpoints", vim.log.levels.WARN)
        return
    end
    if name and name ~= "" then
        _toggle_data_bp(sess, name)
    else
        vim.ui.input({ prompt = "Watch (data breakpoint): ", default = vim.fn.expand("<cword>") },
            function(input)
                if input and input ~= "" then _toggle_data_bp(sess, input) end
            end)
    end
end

---Remove all data breakpoints on the active session.
function M.breakpoint.data_clear()
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    sess:clear_data_breakpoints()
end

---List data breakpoints on the active session; selecting one removes it.
function M.breakpoint.data_list()
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    local bps = sess:data_breakpoints()
    if #bps == 0 then
        vim.notify("[dap] no data breakpoints", vim.log.levels.INFO); return
    end
    select.open({
        prompt = "Remove data breakpoint",
        items  = vim.tbl_map(function(bp)
            local chunks = {
                { bp.verified == false and "◌ " or "◉ ", bp.verified == false and "NonText" or "Special" },
                { bp.name, nil },
            }
            if bp.access_type then
                chunks[#chunks + 1] = { "  [" .. bp.access_type .. "]", "Comment" }
            end
            return { chunks = chunks, data = bp }
        end, bps),
    }, function(bp)
        if bp then sess:remove_data_breakpoint(bp.data_id) end
    end)
end

-- Debug controls

M.debug = {}

function M.debug.continue() manager.continue() end

function M.debug.continue_all() manager.continue_all() end

function M.debug.step_over() manager.next() end

function M.debug.step_in() manager.step_in() end

function M.debug.step_out() manager.step_out() end

---Step back one instruction (reverse debugging). Requires supportsStepBack.
function M.debug.step_back()
    _with_capability("supportsStepBack", "step back", function() manager.step_back() end)
end

---Resume reverse execution until a breakpoint is hit. Requires supportsStepBack.
function M.debug.reverse_continue()
    _with_capability("supportsStepBack", "reverse continue", function() manager.reverse_continue() end)
end

function M.debug.pause() manager.pause() end

---Restart the debuggee. Requires supportsRestartRequest.
function M.debug.restart()
    _with_capability("supportsRestartRequest", "restart", function() manager.restart() end)
end

function M.debug.stop() manager.stop() end

function M.debug.stop_all() manager.stop_all() end

---Step into a specific call on the current line. Prompts when the line has
---multiple call targets; falls back to a plain step-in when the adapter reports
---none. Requires supportsStepInTargetsRequest.
function M.debug.step_in_target()
    _with_capability("supportsStepInTargetsRequest", "step-in targets", function(sess)
        local frame = sess:current_stack_frame()
        if not frame then
            vim.notify("[dap] no selected frame", vim.log.levels.WARN); return
        end
        manager.step_in_targets(frame.id, function(targets, err)
            if err then
                vim.notify("[dap] step-in targets failed: " .. err, vim.log.levels.WARN)
                return
            end
            if not targets or #targets == 0 then
                manager.step_in(); return
            end
            if #targets == 1 then
                manager.step_in(targets[1].id)
                return
            end
            select.open({
                prompt = "Step into",
                items  = vim.tbl_map(function(t) return { chunks = { { t.label } }, data = t } end, targets),
            }, function(t)
                if t then manager.step_in(t.id) end
            end)
        end)
    end)
end

---Jump-to-cursor: set the next statement to execute to the line under the
---cursor in the current buffer. Prompts when the line has multiple targets.
function M.debug.jump_to_cursor()
    _with_capability("supportsGotoTargetsRequest", "jump to cursor", function()
        local path = vim.api.nvim_buf_get_name(0)
        if path == "" then
            vim.notify("[dap] current buffer has no file", vim.log.levels.WARN); return
        end
        local line = vim.api.nvim_win_get_cursor(0)[1]
        ---@type ndap.dap.proto.Source
        local source = { path = path, name = vim.fn.fnamemodify(path, ":t") }
        manager.goto_targets(source, line, function(targets, err)
            if not targets or #targets == 0 then
                vim.notify("[dap] no jump target at this line" .. (err and (": " .. err) or ""),
                    vim.log.levels.WARN)
                return
            end
            if #targets == 1 then
                manager.set_next_statement(targets[1].id)
                return
            end
            select.open({
                prompt = "Jump to",
                items  = vim.tbl_map(function(t)
                    local chunks = { { t.label, nil } }
                    if t.line then chunks[#chunks + 1] = { "  :" .. t.line, "Number" } end
                    return { chunks = chunks, data = t }
                end, targets),
            }, function(t)
                if t then manager.set_next_statement(t.id) end
            end)
        end)
    end)
end

---Restart execution of the currently selected stack frame.
function M.debug.restart_frame()
    _with_capability("supportsRestartFrame", "restart frame", function(sess)
        local frame = sess:current_stack_frame()
        if not frame then
            vim.notify("[dap] no selected frame", vim.log.levels.WARN); return
        end
        manager.restart_frame(frame.id)
    end)
end

---Show detailed information about the exception at the current stop in a float.
function M.debug.exception_info()
    exception_info.show()
end

---Return the active visual selection as one string (lines joined with newlines), or
---nil when there is none. Reads the `v`/`.` positions while still in visual mode
---(leaving it afterwards), or the `'<`/`'>` marks when `from_range` is true.
---@param from_range? boolean
---@return string?
local function _visual_selection(from_range)
    local mode = vim.fn.mode()
    local p1, p2, kind
    if mode:match("^[vV\22]") then
        p1, p2, kind = vim.fn.getpos("v"), vim.fn.getpos("."), mode
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    elseif from_range then
        p1, p2, kind = vim.fn.getpos("'<"), vim.fn.getpos("'>"), vim.fn.visualmode()
    else
        return nil
    end
    local region = vim.fn.getregion(p1, p2, { type = kind ~= "" and kind or "v" })
    if vim.tbl_isempty(region) then return nil end
    return table.concat(region, "\n")
end

-- Cap the inspected expression: a huge selection is almost always a mistake, and
-- an oversized `evaluate` body just burdens the adapter for no useful result.
local _MAX_INSPECT_LEN = 1000

---The expression the inspect commands act on, or nil (with a warning) when there
---is nothing usable to evaluate.
---@param expr? string
---@param from_range? boolean
---@return string?
local function _inspect_target(expr, from_range)
    expr = expr or _visual_selection(from_range) or vim.fn.expand("<cword>")
    if not expr or expr == "" then
        vim.notify("[dap] nothing to inspect", vim.log.levels.WARN)
        return nil
    end
    if #expr > _MAX_INSPECT_LEN then
        vim.notify(
            ("[dap] expression too long to inspect (%d > %d chars)"):format(#expr, _MAX_INSPECT_LEN),
            vim.log.levels.WARN)
        return nil
    end
    return expr
end

---@param expr? string       defaults to the visual selection, else the word under cursor
---@param from_range? boolean true when invoked with a command range (`:'<,'>Debug inspect`)
function M.debug.inspect(expr, from_range)
    expr = _inspect_target(expr, from_range)
    if expr then require("ndap.ui.InspectView").open(expr) end
end

---Like `inspect`, but shows the evaluated value in full right away instead of the
---expandable tree: what `K` does on an inspect-tree node.
---@param expr? string       defaults to the visual selection, else the word under cursor
---@param from_range? boolean true when invoked with a command range (`:'<,'>Debug value`)
function M.debug.value(expr, from_range)
    expr = _inspect_target(expr, from_range)
    if expr then require("ndap.ui.value_hover").evaluate(expr) end
end

---Open the disassembly pane for the active session's current frame.
function M.debug.disassemble() M.view.disassembly_view():open() end

function M.debug.session()
    local sessions = manager.sessions()
    local ids      = vim.tbl_keys(sessions)
    if #ids == 0 then
        vim.notify("[dap] no active sessions", vim.log.levels.WARN); return
    end
    table.sort(ids)
    local active = manager.active_id()
    select.open({
        prompt = "Select session",
        items  = vim.tbl_map(function(id)
            local s      = sessions[id]
            local chunks = {
                { s.config.name or s.config.adapter or "session", id == active and "Special" or nil },
                { "  [" .. s.state .. "]", "Comment" },
            }
            if id == active then chunks[#chunks + 1] = { "  *", "Special" } end
            return { chunks = chunks, data = id }
        end, ids),
    }, function(id)
        if id then manager.select_session(id) end
    end)
end

function M.debug.thread()
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    local threads = sess.threads
    if #threads == 0 then
        vim.notify("[dap] no threads available", vim.log.levels.WARN); return
    end
    local current    = sess:current_thread()
    local current_id = current and current.id or nil
    select.open({
        prompt = "Select thread",
        items  = vim.tbl_map(function(t)
            return {
                chunks = {
                    { "[" .. format.thread_status(t.status) .. "] ", "Comment" },
                    { t.id .. ": ", "NonText" },
                    { t.name, t.id == current_id and "Special" or nil },
                },
                data   = t,
            }
        end, threads),
    }, function(t)
        if t then manager.select_thread(t.id) end
    end)
end

---Prompt for a thread and terminate it (requires supportsTerminateThreadsRequest).
function M.debug.terminate_thread()
    _with_capability("supportsTerminateThreadsRequest", "terminate thread", function(sess)
        local threads = sess.threads
        if #threads == 0 then
            vim.notify("[dap] no threads available", vim.log.levels.WARN); return
        end
        select.open({
            prompt = "Terminate thread",
            items  = vim.tbl_map(function(t)
                return {
                    chunks = {
                        { t.id .. ": ", "NonText" },
                        { t.name, nil },
                        { "  [" .. format.thread_status(t.status) .. "]", "Comment" },
                    },
                    data   = t,
                }
            end, threads),
        }, function(t)
            if t then manager.terminate_threads({ t.id }) end
        end)
    end)
end

function M.debug.frame()
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    local thread = sess:current_thread()
    if not thread then
        vim.notify("[dap] no selected thread", vim.log.levels.WARN); return
    end
    if thread.status ~= "stopped" then
        vim.notify("[dap] cannot select frame while running", vim.log.levels.WARN); return
    end
    local frames = thread.stack_frames or {}
    if #frames == 0 then
        vim.notify("[dap] no stack frames available", vim.log.levels.WARN); return
    end
    local cur_frame = sess:current_stack_frame()
    ---@param f ndap.dap.proto.StackFrame
    ---@return string?
    local function frame_loc(f)
        if not (f.source and f.source.path) then return nil end
        return vim.fn.fnamemodify(f.source.path, ":~:.") .. ":" .. (f.line or "?")
    end
    ---@param f ndap.dap.proto.StackFrame
    ---@return string
    local function frame_key(f)
        local loc = frame_loc(f)
        return f.name .. (loc and ("  " .. loc) or "")
    end
    local cur_key = cur_frame and frame_key(cur_frame) or nil
    local initial ---@type integer?
    local items   = {}
    for i, f in ipairs(frames) do
        -- Match the active frame by its rendered string, not its id.
        local key    = frame_key(f)
        local is_cur = cur_key ~= nil and not initial and key == cur_key
        if is_cur then initial = i end
        local data = { frame = f }
        local loc  = frame_loc(f)
        if f.source and f.source.path then
            data.filepath = f.source.path
            data.lnum     = f.line
        end
        -- Name, marker and location each carry their own highlight, so the
        -- eye separates the frame from the source position at a glance.
        local chunks = { { f.name, is_cur and "Special" or nil } }
        if is_cur then chunks[#chunks + 1] = { "  *", "Special" } end
        if loc then chunks[#chunks + 1] = { "  " .. loc, "Comment" } end
        items[i] = { chunks = chunks, data = data }
    end
    select.open({
        prompt          = "Select frame",
        enable_preview  = true,
        items           = items,
        initial         = initial,
        -- Call order is the frame list's meaning; keep it while filtering.
        sort_by_score   = false,
        -- Long paths would otherwise wrap and break the one-row-per-frame list.
        list_wrap       = false,
    }, function(data)
        if not data then return end
        -- The thread may have resumed while the picker was open.
        local t = sess:current_thread()
        if not t or t.status ~= "stopped" then
            vim.notify("[dap] cannot select frame while running", vim.log.levels.WARN); return
        end
        manager.select_frame(data.frame.id)
    end)
end

-- Debug view

M.view = {}

---Return the singleton DebugView, creating it on first call.
---@return ndap.DebugView
function M.view.debug_view()
    if not _debug_view then
        _debug_view = require("ndap.ui.DebugView").new()
    end
    return _debug_view
end

---The singleton DebugView if one exists, else nil. Never creates one: for
---callers that only act on a view already on screen.
---@return ndap.DebugView?
function M.view.debug_view_if_open()
    return _debug_view
end

---Return the singleton DisassemblyView, creating it on first call.
---@return ndap.DisassemblyView
function M.view.disassembly_view()
    if not _disassembly_view then
        _disassembly_view = require("ndap.ui.DisassemblyView").new()
    end
    return _disassembly_view
end

---The singleton DisassemblyView if one exists, else nil. Never creates one: for
---callers that only act on a view already on screen, such as routing a
---breakpoint toggle from a disassembly buffer.
---@return ndap.DisassemblyView?
function M.view.disassembly_view_if_open()
    return _disassembly_view
end

---Open the DebugView split, focusing it when it is already visible.
function M.view.open()
    M.view.debug_view():open()
end

---Close the DebugView split. No-op when it is not visible.
function M.view.hide()
    if not _debug_view then return end
    _debug_view:close()
end

---Toggle the DebugView split: close it if visible, otherwise open and focus it.
function M.view.toggle()
    M.view.debug_view():toggle()
end

-- Panel

M.panel = {}

---Toggle the bottom window a run's buffers are shown in. A no-op before
---`setup`, when the window is not in play yet.
function M.panel.toggle()
    require("ndap.ui.Panel").toggle()
end

return M
