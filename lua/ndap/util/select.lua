---@brief Standalone floating fuzzy picker for ndap.
---A self-contained replacement for `vim.ui.select`: a floating prompt with
---type-to-filter fuzzy matching, an item list, and an optional file-based
---preview pane. No external picker dependency.

local M                  = {}

local fsutil             = require("ndap.util.fsutil")
local ui_util            = require("ndap.util.ui")
local timer              = require("ndap.util.timer")

local _NS_CURSOR         = vim.api.nvim_create_namespace("ndap_select_cursor")
local _NS_CONTENT        = vim.api.nvim_create_namespace("ndap_select_content")
local _NS_PROMPT         = vim.api.nvim_create_namespace("ndap_select_prompt")
local _NS_PREVIEW        = vim.api.nvim_create_namespace("ndap_select_preview")

local _antiflicker_delay = 200

---Fills the list's winbar, so it reads as the rule between prompt and items.
local _RULE              = "─"

---`NonText`'s foreground over the window's own background. The rule is drawn in
---it: a `NonText` carrying a background of its own would otherwise paint the
---row in it, breaking it against the list around it.
local _HL_RULE           = "NdapSelectRule"

local function _set_rule_hl()
    local src = vim.api.nvim_get_hl(0, { name = "NonText", link = false })
    vim.api.nvim_set_hl(0, _HL_RULE, {
        fg      = src.fg,
        ctermfg = src.ctermfg,
        bg      = "NONE",
        ctermbg = "NONE",
    })
end

_set_rule_hl()

-- `:colorscheme` clears the derived group along with the one it came from.
vim.api.nvim_create_autocmd("ColorScheme", {
    group    = vim.api.nvim_create_augroup("ndap_select_rule_hl", { clear = true }),
    callback = _set_rule_hl,
})

---@class ndap.select.ItemData
---@field filepath string?
---@field lnum integer?
---@field col integer?
---@field [string] any

---@class ndap.select.Item
---@field chunks {[1]:string,[2]:string?}[]  -- label text with optional highlights; matched as their concatenation
---@field data ndap.select.ItemData?  -- passed to the callback and previewer

---@class ndap.select.Preview
---@field content string|string[]|nil
---@field filetype string?
---@field filepath string?
---@field pos integer[]?  -- { lnum (1-based), col (0-based) }
---@field error_msg string?

---@alias ndap.select.Previewer fun(data:any, callback:fun(preview:ndap.select.Preview?)):(fun()?)

---@class ndap.select.Opts
---@field prompt string?
---@field items (ndap.select.Item|string)[]  -- a bare string is its own label
---@field sort_by_score boolean?  -- best match first while filtering (default true); false when the supplied order is itself the meaning
---@field enable_preview boolean?  -- makes the preview available; <C-t> shows it (hidden by default)
---@field previewer ndap.select.Previewer?  -- defaults to the built-in file previewer
---@field initial integer?  -- 1-based index of the item to pre-select (cursor starts on it)
---@field height_ratio number?  -- fraction of the usable rows the bar spans (default 0.25)
---@field preview_ratio number?  -- share of the frame's width the preview takes (default 0.5)
---@field list_wrap boolean?

---@class ndap.select.Layout
---@field prompt_row integer
---@field prompt_col integer
---@field prompt_width integer  -- same as `list_width`: they share one frame
---@field prompt_height integer
---@field prompt_border string|table
---@field list_row integer
---@field list_col integer
---@field list_width integer
---@field list_height integer
---@field list_border string|table
---@field preview_row integer
---@field preview_col integer
---@field preview_width integer
---@field preview_height integer
---@field preview_border string|table

---@class ndap.select.SourceItem
---@field label string  -- the chunks' text, matched against the query
---@field chunks {[1]:string,[2]:string?}[]  -- sanitized caller chunks
---@field data any

---@class ndap.select.ListItem
---@field label string
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field score number?
---@field data any

-- Helpers

---Rows and columns the outermost border eats: `nvim_open_win` draws a border on
---the row and column it is handed, so a float reaches one cell past the geometry
---on every side. Centering has to allow for it or the picker sits low and right.
local _BORDER_SPAN       = 2

-- Helix-style framing. The rule between the two halves is drawn by neither
-- border: it is the list's winbar, filled with `_RULE` and carrying the position
-- count at its right end. A winbar is a window-local option, so a changing count
-- neither re-configures a window nor touches the focused prompt.
local _BORDER_TOP        = { "╭", "─", "╮", "│", "", "", "", "│" }
local _BORDER_BOTTOM     = { "", "", "", "│", "╯", "─", "╰", "│" }
local _BORDER_FULL       = "rounded"

-- Indent every list row sits at, shared by rendering and wrapped-line indent.
local _ROW_PREFIX        = "  "

-- Rows the prompt float covers for a one-line query: its top border and the
-- line of text. The rule under them is the list's winbar.
local _PROMPT_ROWS       = 2

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

--- Whether a statusline is drawn at the bottom of the editor. With
--- `laststatus == 1`, assume no status line
---@return boolean
local function _has_statusline()
    local laststatus = vim.o.laststatus
    return laststatus ~= 0 and laststatus ~= 1
end

---Editor rows the picker may occupy: everything `vim.o.lines` counts, less the
---command line and the statusline. Floats are placed relative to the editor,
---whose row 0 is the top of the screen, so those rows come off the bottom.
---@return integer
local function _usable_lines()
    local reserved = vim.o.cmdheight + (_has_statusline() and 1 or 0)
    return math.max(1, vim.o.lines - reserved)
end

---Divide the rows the prompt/list frame holds between a one-line prompt and the
---list below it. `interior` counts everything inside the frame's border, the
---rule between the two included.
---@param interior integer
---@return integer prompt_height, integer list_height
local function _split_frame(interior)
    local prompt_height = 1
    return prompt_height, math.max(1, interior - 1 - prompt_height)
end

---The frame's top row, width and interior height. `expanded` fills the usable
---editor top to bottom; otherwise the frame is a bar against its bottom,
---`height_ratio` of the usable rows tall. The border ring is excluded from the
---interior in both cases.
---@param height_ratio number?
---@param expanded boolean
---@return integer row
---@return integer width
---@return integer interior
local function _frame(height_ratio, expanded)
    -- A content width of `cols - 4` plus the two border columns spans all but
    -- one cell at either edge of the editor.
    local width = math.max(1, vim.o.columns - 4)

    if expanded then
        -- Border flush with the first and last usable rows.
        return 0, width, math.max(3, _usable_lines() - _BORDER_SPAN)
    end

    local lines        = _usable_lines()
    local total_height = math.ceil(lines * _clamp(height_ratio or 0.25, 0.1, 0.9))
    -- Room for the prompt line, the rule and an item row.
    total_height = math.min(math.max(3, total_height), math.max(3, lines - _BORDER_SPAN))
    return math.max(0, lines - total_height - _BORDER_SPAN), width, total_height
end

---Prompt and list in the frame, with the preview -- when shown -- on its right
---half. The preview runs the full height of the frame, so the split looks the
---same however tall the frame is.
---@param height_ratio number?
---@param preview_ratio number?
---@param expanded boolean
---@param preview boolean
---@return ndap.select.Layout
local function _build_layout(height_ratio, preview_ratio, expanded, preview)
    local row, width, total_height = _frame(height_ratio, expanded)
    local prompt_height, list_height = _split_frame(total_height)

    -- Each box keeps its own border ring, and they touch: sharing a column
    -- would put both boxes' corners on the same cell.
    local list_width, preview_width = width, 0
    if preview then
        local ratio = _clamp(preview_ratio or 0.5, 0.1, 0.9)
        preview_width = math.max(1, math.floor((width - 2) * ratio))
        list_width    = math.max(1, width - preview_width - 2)
    end

    local col = 1

    return {
        prompt_row     = row,
        prompt_col     = col,
        prompt_width   = list_width,
        prompt_height  = prompt_height,
        prompt_border  = _BORDER_TOP,

        list_row       = row + _PROMPT_ROWS + prompt_height - 1,
        list_col       = col,
        list_width     = list_width,
        list_height    = list_height,
        list_border    = _BORDER_BOTTOM,

        -- Top border level with the prompt's, bottom border with the list's.
        preview_row    = row,
        preview_col    = list_width + 3,
        preview_width  = preview_width,
        preview_height = preview and list_height + 2 or 0,
        preview_border = _BORDER_FULL,
    }
end

---Split `chunks` around the matched characters, which take `hl_group`; the
---rest keeps the highlight it came in with.
---@param chunks {[1]:string,[2]:string?}[]
---@param positions integer[]  matched (1-based) indices into the concatenated text
---@param hl_group string?  override for the match highlight (default `Visual`)
---@return {[1]:string,[2]:string?}[] chunks
local function _apply_match_highlight(chunks, positions, hl_group)
    if not positions or #positions == 0 then return chunks end

    local hl      = hl_group or "Visual"
    local pos_map = {}
    for _, p in ipairs(positions) do pos_map[p] = true end

    local out      = {}
    local char_idx = 0

    for _, chunk in ipairs(chunks) do
        local text, chunk_hl = chunk[1], chunk[2]
        local current, current_hl

        for i = 1, vim.fn.strchars(text) do
            local char    = vim.fn.strcharpart(text, i - 1, 1)
            local char_hl = pos_map[char_idx + 1] and hl or chunk_hl
            char_idx = char_idx + 1

            if current == nil then
                current, current_hl = char, char_hl
            elseif char_hl == current_hl then
                current = current .. char
            else
                table.insert(out, { current, current_hl })
                current, current_hl = char, char_hl
            end
        end
        if current ~= nil then table.insert(out, { current, current_hl }) end
    end
    return out
end

---Flatten caller chunks into the one-line label a list row holds, keeping each
---chunk's highlight. The label is the chunks' text, so fuzzy-match positions
---line up with them.
---@param chunks {[1]:string,[2]:string?}[]
---@return string label, {[1]:string,[2]:string?}[] sanitized
local function _normalize_chunks(chunks)
    local parts, out = {}, {}
    for i, chunk in ipairs(chunks) do
        local text = (tostring(chunk[1] or ""):gsub("\n", " "))
        parts[i] = text
        out[i]   = { text, chunk[2] }
    end
    return table.concat(parts), out
end

---@param text string  what we match against
---@param query string  user input
---@param item_chunks {[1]:string,[2]:string?}[]?  pre-highlighted label; must concatenate to `text`
---@return { score:number, chunks:{[1]:string,[2]:string?}[] }?  nil when the query doesn't match
local function _match_label(text, query, item_chunks)
    local chunks = item_chunks or { { text } }
    if query == "" then
        return { score = 0, chunks = chunks }
    end
    local result = vim.fn.matchfuzzypos({ text }, query)
    if #result[1] == 0 then return nil end
    local raw_positions = result[2][1]
    local positions     = {}
    for _, p in ipairs(raw_positions) do
        positions[#positions + 1] = p + 1 -- matchfuzzypos is 0-based; chunk builder is 1-based
    end
    return {
        score  = result[3][1],
        chunks = _apply_match_highlight(chunks, positions),
    }
end

---Best match first. `table.sort` is not stable, so equal scores fall back to the
---items' source order; otherwise a keystroke that doesn't change any score
---would still shuffle the list under the cursor.
---@param items ndap.select.ListItem[]
local function _sort_by_score(items)
    local order = {}
    for i, item in ipairs(items) do order[item] = i end
    table.sort(items, function(a, b)
        local sa, sb = a.score or 0, b.score or 0
        if sa == sb then return order[a] < order[b] end
        return sa > sb
    end)
end

---The built-in file previewer. Reads `data.filepath`/`data.lnum`/`data.col` and
---asynchronously loads the file content. Cancellable via the returned function.
---@type ndap.select.Previewer
local function _file_preview(data, callback)
    local _max_size = 10124 * 10124
    local _filepath = data and data.filepath
    if not _filepath or _filepath == "" then
        callback({})
        return
    end
    if not fsutil.file_exists(_filepath) then
        callback({ error_msg = "Invalid file path: " .. tostring(_filepath) })
        return
    end
    local _cancelled = false
    local _cancel_fn
    vim.uv.fs_stat(_filepath, vim.schedule_wrap(function(stat_err, stat)
        if _cancelled then return end
        if stat_err or not stat then
            callback({ error_msg = stat_err })
            return
        end
        if stat.size > _max_size then
            callback({ error_msg = "Maximum file size exceeded" })
            return
        end
        _cancel_fn = fsutil.async_load_text_file(_filepath, { timeout = 3000 },
            function(load_err, content)
                callback({
                    content   = content,
                    filepath  = _filepath,
                    pos       = data.lnum and { data.lnum, data.col or 0 } or nil,
                    error_msg = load_err,
                })
            end)
    end))
    return function()
        _cancelled = true
        if _cancel_fn then _cancel_fn() end
    end
end

---Place the preview cursor and highlight the target line.
---@param win integer
---@param buf integer
---@param pos integer[]?  -- { lnum (1-based), col (0-based) }
local function _apply_preview_pos(win, buf, pos)
    vim.api.nvim_buf_clear_namespace(buf, _NS_PREVIEW, 0, -1)
    if not pos then
        pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
        return
    end
    local lnum      = _clamp(pos[1], 1, vim.api.nvim_buf_line_count(buf))
    local line_text = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    local col       = math.max(0, math.min(pos[2] or 0, #line_text))
    pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
    vim.api.nvim_buf_set_extmark(buf, _NS_PREVIEW, lnum - 1, 0, {
        end_row  = lnum,
        hl_group = "Visual",
        hl_eol   = true,
        hl_mode  = "blend",
    })
end

---@param msg string
---@param width number
---@param height number
---@return string[]
local function _center_for_previewer(msg, width, height)
    local pad_left = math.max(0, math.floor((width - #msg) / 2) + 1)
    local centered = string.rep(" ", pad_left) .. msg
    local pad_top  = math.max(0, math.floor((height + 1) / 2))

    local lines    = {}
    for _ = 1, pad_top do table.insert(lines, "") end
    table.insert(lines, centered)
    return lines
end

-- Picker

---@type ndap.select.Picker?
local _active_picker = nil

---@class ndap.select.Picker
---@field opts ndap.select.Opts
---@field callback fun(data:any?)
---@field preview_enabled boolean
---@field expanded boolean  -- the frame fills the editor rather than sitting on the bar
---@field preview_open boolean  -- the preview float is up
---@field layout ndap.select.Layout
---@field query_text string
---@field closed boolean
---@field pbuf integer?
---@field lbuf integer?
---@field vbuf integer?
---@field pwin integer?
---@field lwin integer?
---@field vwin integer?
---@field list_items ndap.select.ListItem[]
---@field async_preview_context integer
---@field async_preview_cancel fun()?
---@field preview_timer table?
---@field _source_items ndap.select.SourceItem[]
---@field _initial integer?
---@field _position_text string?  -- "cursor/total" currently in the list winbar
local Picker = {}
Picker.__index = Picker

function Picker:new(...)
    local obj = setmetatable({}, self)
    obj:init(...)
    return obj
end

---@param opts ndap.select.Opts
---@param callback fun(data:any?)
function Picker:init(opts, callback)
    self.opts                  = opts
    self.callback              = callback
    self.preview_enabled       = opts.enable_preview or false
    -- The picker opens as a bar; the preview and the expanded list are each one
    -- keypress away, and independent of each other.
    self.expanded              = false
    self.preview_open          = false
    self.closed                = false
    self.query_text            = ""
    self.list_items            = {}
    self.async_preview_context = 0
    self.async_preview_cancel  = nil

    ---@type ndap.select.SourceItem[]
    self._source_items = {}
    for idx, it in ipairs(opts.items or {}) do
        local data, chunks
        if type(it) == "string" then
            data, chunks = it, { { it } }
        else
            assert(type(it.chunks) == "table",
                string.format("select item %d is missing `chunks`", idx))
            data, chunks = it.data, it.chunks
        end
        local label
        label, chunks = _normalize_chunks(chunks)
        table.insert(self._source_items, { label = label, chunks = chunks, data = data })
    end

    self._initial = type(opts.initial) == "number" and opts.initial or nil

    if _active_picker and not _active_picker.closed then
        _active_picker:close()
    end
    _active_picker = self

    self:create_windows()
    self:setup_input()

    assert(self.pwin)
    vim.api.nvim_set_current_win(self.pwin)

    self:run_filter()
    vim.schedule(function()
        if not self.closed then vim.cmd("startinsert!") end
    end)
end

---The list window's winbar: the rule, with `position_text` at its right end. The
---rule itself is the `wbr` fill char stretched by `%=`, so the winbar is never
---empty -- an empty 'winbar' would take the row back and pull the list up.
---@param position_text string?
---@return string
local function _lwin_winbar(position_text)
    return "%#" .. _HL_RULE .. "#%=" .. (position_text and (" " .. position_text) or "")
end

---The three floats' configs, built off `self.layout`. The border is per float
---and comes from the layout: prompt and list share one frame, each drawing the
---half of it that is theirs.
---@return { prompt:table, list:table, preview:table }
function Picker:_float_cfgs()
    local l     = self.layout
    local title = self.opts.prompt and (" " .. self.opts.prompt .. " ") or ""

    ---@param cfg table Placement and border, read off the layout.
    ---@return table
    local function float_cfg(cfg)
        return vim.tbl_extend("force", { relative = "editor", style = "minimal" }, cfg)
    end

    return {
        prompt  = float_cfg {
            row       = l.prompt_row,
            col       = l.prompt_col,
            width     = l.prompt_width,
            height    = l.prompt_height,
            border    = l.prompt_border,
            title     = title,
            title_pos = "center",
        },
        -- The list has no top border: its first row is the winbar drawing the
        -- rule above the items, which is what the extra row of height pays for.
        list    = float_cfg {
            row    = l.list_row,
            col    = l.list_col,
            width  = l.list_width,
            height = l.list_height + 1,
            border = l.list_border,
        },
        preview = float_cfg {
            row    = l.preview_row,
            col    = l.preview_col,
            width  = l.preview_width,
            height = l.preview_height,
            border = l.preview_border,
        },
    }
end

---Shared window highlights: the picker floats read as plain windows.
local _WINHL = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title," ..
    "WinBar:Normal,WinBarNC:Normal"

---Recompute `self.layout` from the current editor size, view and ratios.
---`preview` overrides whether the right half is reserved, for a caller that is
---about to create or has just destroyed the preview window.
---@param preview boolean?
function Picker:_compute_layout(preview)
    if preview == nil then preview = self.preview_open end
    self.layout = _build_layout(
        self.opts.height_ratio,
        self.opts.preview_ratio,
        self.expanded,
        preview
    )
end

---Move `win` to `cfg`, unless it already sits there.
---@param win integer?
---@param cfg table
---@return boolean moved
function Picker:_resize_window(win, cfg)
    if not win or not vim.api.nvim_win_is_valid(win) then return false end
    local cur = vim.api.nvim_win_get_config(win)
    if cur.relative == cfg.relative
        and cur.row == cfg.row
        and cur.col == cfg.col
        and cur.width == cfg.width
        and cur.height == cfg.height then
        return false
    end
    vim.api.nvim_win_set_config(win, cfg)
    return true
end

---Move the open floats to `cfgs`. Nothing else: the windows exist and keep the
---buffers and options they were created with.
---@param cfgs { prompt:table, list:table, preview:table }
---@return boolean list_moved
function Picker:_resize_windows(cfgs)
    self:_resize_window(self.pwin, cfgs.prompt)
    local list_moved = self:_resize_window(self.lwin, cfgs.list)
    if self.vwin then self:_resize_window(self.vwin, cfgs.preview) end
    return list_moved
end

---Settle the layout for the current editor size and move the floats onto it.
---@param preview boolean?
---@return boolean list_moved
function Picker:_apply_layout(preview)
    self:_compute_layout(preview)
    return self:_resize_windows(self:_float_cfgs())
end

---Draw the marker in front of the query as inline virtual text: it takes screen
---cells, not buffer ones, so the line stays what the filter reads and the cursor
---sits after the marker.
---@return nil
function Picker:_render_prompt_marker()
    vim.api.nvim_buf_clear_namespace(self.pbuf, _NS_PROMPT, 0, -1)
    vim.api.nvim_buf_set_extmark(self.pbuf, _NS_PROMPT, 0, 0, {
        virt_text     = { { "❯ ", "NonText" } },
        virt_text_pos = "inline",
        right_gravity = false,
    })
end

---Create the picker's buffers and windows. Called once, at open; afterwards the
---windows are only moved and resized, by `relayout()`.
function Picker:create_windows()
    if self.closed then return end
    self:_compute_layout()
    local cfgs = self:_float_cfgs()

    -- Prompt window
    self.pbuf = ui_util.create_scratch_buffer(false, { modifiable = true }, function()
        self.pbuf = nil
        if not self.closed then vim.schedule(function() self:close() end) end
    end)
    self:_render_prompt_marker()
    local pwin_augroup
    self.pwin, pwin_augroup = ui_util.create_window(self.pbuf, true, cfgs.prompt, function()
        self.pwin = nil
        if not self.closed then vim.schedule(function() self:close() end) end
    end)
    local pwo = vim.wo[self.pwin][0]
    pwo.winhighlight = _WINHL
    pwo.wrap = false

    assert(type(pwin_augroup) == "number")
    vim.api.nvim_create_autocmd("WinEnter", {
        group = pwin_augroup,
        callback = function()
            if self.closed then return end
            local win      = vim.api.nvim_get_current_win()
            local cfg      = vim.api.nvim_win_get_config(win)
            local is_float = cfg.relative and cfg.relative ~= ""
            if not is_float and win ~= self.pwin and win ~= self.lwin and win ~= self.vwin then
                vim.schedule(function() self:close() end)
            end
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
        group = pwin_augroup,
        callback = function()
            if self.closed then return end
            vim.schedule(function() self:relayout() end)
        end,
    })

    -- List window
    self.lbuf = ui_util.create_scratch_buffer(false, { modifiable = false }, function()
        self.lbuf = nil
        if not self.closed then vim.schedule(function() self:close() end) end
    end)
    self.lwin = ui_util.create_window(self.lbuf, false, cfgs.list, function()
        self.lwin = nil
        if not self.closed then vim.schedule(function() self:close() end) end
    end)
    local lwo = vim.wo[self.lwin][0]
    lwo.winhighlight = _WINHL
    lwo.wrap = self.opts.list_wrap ~= false
    lwo.cursorline = false
    lwo.breakindent = true
    -- `wbr` is what `%=` stretches across the winbar; `eob` comes with the
    -- window's `style = "minimal"`, and setting 'fillchars' here drops it.
    lwo.fillchars = "eob: ,wbr:" .. _RULE
    lwo.winbar = _lwin_winbar(self._position_text)
end

---Put up the preview float. It exists only while the preview is shown, so it is
---created when `<C-t>` asks for it rather than with the picker.
function Picker:_create_preview_window()
    if self.vwin or not self.preview_enabled then return end
    local cfgs = self:_float_cfgs()

    self.vbuf = ui_util.create_scratch_buffer(false, { modifiable = false }, function()
        self.vbuf = nil
    end)
    local vkey = { buffer = self.vbuf, nowait = true, silent = true }
    vim.keymap.set("n", "<CR>", function() self:confirm() end, vkey)
    vim.keymap.set("n", "<Esc>", function() self:close() end, vkey)

    self.vwin = ui_util.create_window(self.vbuf, false, cfgs.preview, function()
        self.vwin = nil
    end)
    local vwo = vim.wo[self.vwin][0]
    vwo.wrap = true
    vwo.winhighlight = _WINHL
end

---Take the preview float down on the switch back to a view without it, and
---drop whatever it was waiting on.
function Picker:_destroy_preview_window()
    if self.async_preview_cancel then
        self.async_preview_cancel()
        self.async_preview_cancel = nil
    end
    self.preview_timer = timer.stop_and_close_timer(self.preview_timer)

    local win, buf = self.vwin, self.vbuf
    self.vwin, self.vbuf = nil, nil
    if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        vim.api.nvim_buf_delete(buf, { force = true })
    end
end

---Show the preview on the right half of the frame, or take it down. Nothing
---happens for a picker opened without one.
function Picker:toggle_preview()
    if self.closed or not self.preview_enabled then return end
    if self.preview_open then
        self.preview_open = false
        self:_destroy_preview_window()
        self:_apply_layout()
        self:render_cursor()
        return
    end
    self.preview_open = true
    self:_apply_layout(true)
    self:_create_preview_window()
    self:update_preview()
end

---Fill the screen with the prompt and list, or go back to the compact bar. A
---preview that is showing stays on the right half, and grows with the frame.
function Picker:toggle_expanded()
    if self.closed then return end
    self.expanded = not self.expanded
    self:_apply_layout()
    self:render_cursor()
end

---Move the focus between the prompt and the list. Insert mode is left behind on
---the way out of the prompt and entered again on the way back. The preview is
---left out of the cycle: it can be showing a buffer the picker does not own, and
---binding a key on it would be stepping into someone else's window.
function Picker:_cycle_focus()
    if self.closed then return end

    local wins = {}
    for _, win in ipairs({ self.pwin, self.lwin }) do
        if win and vim.api.nvim_win_is_valid(win) then wins[#wins + 1] = win end
    end
    if #wins == 0 then return end

    local cur = vim.api.nvim_get_current_win()
    local idx = 0
    for i, win in ipairs(wins) do
        if win == cur then
            idx = i
            break
        end
    end

    -- Insert mode is global, not per window: without this the next keystroke
    -- would still be inserted, now into the list buffer.
    vim.cmd("stopinsert")

    local next_win = wins[idx % #wins + 1]
    vim.api.nvim_set_current_win(next_win)
    if next_win == self.pwin then vim.cmd("startinsert") end
end

---Move the floats to the current editor size and draw what the new size
---changed. The windows themselves are put up once by `create_windows`.
function Picker:relayout()
    if self.closed then return end
    self:_apply_layout()
    if self.vwin then self:update_preview() end
end

---Filter `_source_items` by the current query and rebuild the visible list.
function Picker:run_filter()
    local query     = self.query_text
    self.list_items = {}

    for _, src in ipairs(self._source_items) do
        local m = _match_label(src.label, query, src.chunks)
        if m then
            table.insert(self.list_items, {
                label        = src.label,
                label_chunks = m.chunks,
                data         = src.data,
                score        = query ~= "" and m.score or nil,
            })
        end
    end
    -- An empty query has no scores to rank by, so it always keeps the supplied
    -- order; `sort_by_score = false` keeps it while filtering too.
    if query ~= "" and self.opts.sort_by_score ~= false then
        _sort_by_score(self.list_items)
    end

    self:render_list()

    -- `initial` pre-selects a row by index, honoured only on the first
    -- (empty-query) render where the list order still matches the supplied
    -- items; once the user types, the best fuzzy match leads at row 1.
    local target = 1
    if self._initial then
        if #self.list_items > 0 then
            target = _clamp(self._initial, 1, #self.list_items)
        end
        self._initial = nil
    end

    if #self.list_items > 0 and self.lwin and vim.api.nvim_win_is_valid(self.lwin) then
        vim.api.nvim_win_set_cursor(self.lwin, { target, 0 })
    end
    self:render_cursor()
    self:render_position()
    self:update_preview()
end

function Picker:render_list()
    if not self.lbuf then return end
    local prefix   = _ROW_PREFIX
    local lines    = {}
    local extmarks = {}

    for row_idx, item in ipairs(self.list_items) do
        local row = row_idx - 1
        table.insert(lines, prefix .. item.label)
        local col = #prefix
        for _, chunk in ipairs(item.label_chunks or {}) do
            local text, hl = chunk[1], chunk[2]
            if text and #text > 0 then
                if hl then
                    table.insert(extmarks, {
                        row  = row,
                        col  = col,
                        opts = { end_col = col + #text, hl_group = hl },
                    })
                end
                col = col + #text
            end
        end
    end

    vim.bo[self.lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CONTENT, 0, -1)
    for _, mark in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CONTENT, mark.row, mark.col, mark.opts)
    end
    vim.bo[self.lbuf].modifiable = false

    if self.lwin and vim.api.nvim_win_is_valid(self.lwin) then
        vim.wo[self.lwin][0].cursorline = #self.list_items > 0
    end
end

---@return integer?
function Picker:get_cursor()
    if not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return nil end
    return vim.api.nvim_win_get_cursor(self.lwin)[1]
end

---Draw the marker, the counter and the preview for the row the list window's
---cursor is on.
---@return nil
function Picker:_render_selection()
    self:render_cursor()
    self:render_position()
    self:update_preview()
end

---@param row integer
---@param force boolean?
---@param clamp boolean?
function Picker:move_cursor(row, force, clamp)
    if not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return end
    if not self.lbuf then return end
    local total = #self.list_items
    if total == 0 then return end
    if not force and row == self:get_cursor() then return end

    if clamp then
        row = _clamp(row, 1, total)
    else
        if row > total then row = 1 end
        if row < 1 then row = total end
    end

    -- Clear the old marker and hide 'cursorline' while the window scrolls to the
    -- new row: otherwise each row the jump passes over is drawn with them.
    vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CURSOR, 0, -1)
    vim.wo[self.lwin][0].cursorline = false

    vim.api.nvim_win_set_cursor(self.lwin, { row, 0 })
    self:_render_selection()
    vim.wo[self.lwin][0].cursorline = true
end

---Show `cursor/total` right-aligned in the list window's winbar, the rule it
---shares with the prompt.
function Picker:render_position()
    if self.closed or not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return end
    local total = #self.list_items
    local text  = total > 0 and string.format("%d/%d", self:get_cursor() or 1, total) or nil
    if text == self._position_text then return end
    self._position_text = text
    vim.wo[self.lwin][0].winbar = _lwin_winbar(text)
end

function Picker:render_cursor()
    if not self.lbuf then return end
    vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CURSOR, 0, -1)
    local total = #self.list_items
    if total == 0 then return end
    local cur = self:get_cursor() or 1
    vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CURSOR, cur - 1, 0, {
        virt_text     = { { "❯ ", "Special" } },
        virt_text_pos = "overlay",
        priority      = 100,
    })
end

function Picker:update_preview()
    self.async_preview_context = self.async_preview_context + 1
    local preview_context = self.async_preview_context

    if self.closed or not self.preview_open then return end
    if not self.vbuf then return end

    self:request_clear_preview()

    if self.async_preview_cancel then
        self.async_preview_cancel()
        self.async_preview_cancel = nil
    end

    local cursor = self:get_cursor()
    local item   = cursor and self.list_items[cursor] or nil
    if not item then return end

    -- The layout's width and height are what `nvim_open_win` was handed, and it
    -- draws the border outside them, so these are the content area.
    local preview_width       = math.max(0, self.layout.preview_width)
    local preview_height      = math.max(0, self.layout.preview_height)

    local preview_fn          = self.opts.previewer or _file_preview

    self.async_preview_cancel = preview_fn(
        item.data or {},
        vim.schedule_wrap(function(preview)
            if self.closed or preview_context ~= self.async_preview_context then return end
            preview = preview or {}
            self:cancel_clear_preview_req()

            if not self.vbuf or not vim.api.nvim_buf_is_valid(self.vbuf) then return end

            local content = preview.content
            local lines ---@type string[]
            if content then
                lines = type(content) == "string" and vim.split(content, "\n") or content
            elseif preview.error_msg then
                lines = _center_for_previewer(preview.error_msg, preview_width, preview_height)
            else
                lines = _center_for_previewer("No preview", preview_width, preview_height)
            end
            lines = lines or {}

            vim.bo[self.vbuf].modifiable = true
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, lines)
            vim.bo[self.vbuf].modifiable = false

            local filetype = content and (preview.filetype
                or (preview.filepath and vim.filetype.match({ filename = preview.filepath }))
                or "") or ""
            -- don't set bo[].filetype to avoid slowness and flickering triggered by treesiter/lsp etc...
            vim.bo[self.vbuf].syntax = filetype

            if self.vwin and vim.api.nvim_win_is_valid(self.vwin) then
                _apply_preview_pos(self.vwin, self.vbuf, content and preview.pos or nil)
            end
        end)
    )
end

---@param immediate boolean?
function Picker:request_clear_preview(immediate)
    local clear = function()
        if self.vbuf and not self.closed and vim.api.nvim_buf_is_valid(self.vbuf) then
            vim.bo[self.vbuf].modifiable = true
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, {})
            vim.bo[self.vbuf].modifiable = false
            vim.api.nvim_buf_clear_namespace(self.vbuf, _NS_PREVIEW, 0, -1)
        end
    end
    if immediate then
        self:cancel_clear_preview_req()
        clear()
    elseif not self.preview_timer then
        self.preview_timer = vim.defer_fn(function()
            self.preview_timer = nil
            clear()
        end, _antiflicker_delay)
    end
end

function Picker:cancel_clear_preview_req()
    self.preview_timer = timer.stop_and_close_timer(self.preview_timer)
end

function Picker:confirm()
    local cursor = self:get_cursor()
    local item   = cursor and self.list_items[cursor] or nil
    self:close(item and item.data or nil)
end

---@param selected_data any?
function Picker:close(selected_data)
    if self.closed then return end
    self.closed = true
    if _active_picker == self then _active_picker = nil end

    self.preview_timer = timer.stop_and_close_timer(self.preview_timer)
    if self.async_preview_cancel then
        self.async_preview_cancel()
        self.async_preview_cancel = nil
    end

    -- Leaving insert steps the cursor one column left, and `:stopinsert` only
    -- lands once this returns: the floats outlive the call so that step falls
    -- in the prompt rather than in the window focus goes back to.
    vim.cmd("stopinsert!")
    vim.schedule(function()
        for _, w in pairs({ self.pwin, self.lwin, self.vwin }) do
            if w and vim.api.nvim_win_is_valid(w) then
                pcall(vim.api.nvim_win_close, w, true)
            end
        end
        for _, b in pairs({ self.pbuf, self.lbuf, self.vbuf }) do
            if b and vim.api.nvim_buf_is_valid(b) then
                pcall(vim.api.nvim_buf_delete, b, { force = true })
            end
        end
        self.callback(selected_data)
    end)
end

function Picker:setup_input()
    ---@param buf integer
    local function key_opts(buf)
        return { buffer = buf, nowait = true, silent = true }
    end

    local p    = key_opts(self.pbuf)
    local expr = vim.tbl_extend("force", p, { expr = true })

    vim.keymap.set({ "i", "n" }, "<CR>", function() self:confirm() end, p)
    vim.keymap.set("n", "<Esc>", function() self:close() end, p)
    vim.keymap.set("i", "<C-c>", function() self:close() end, p)

    vim.keymap.set("n", "<C-n>", function() self:move_cursor((self:get_cursor() or 0) + 1) end, p)
    vim.keymap.set("n", "<C-p>", function() self:move_cursor((self:get_cursor() or 1) - 1) end, p)

    vim.keymap.set("i", "<C-n>", function()
        if vim.fn.pumvisible() == 1 then return "<C-n>" end
        self:move_cursor((self:get_cursor() or 0) + 1)
        return ""
    end, expr)
    vim.keymap.set("i", "<C-p>", function()
        if vim.fn.pumvisible() == 1 then return "<C-p>" end
        self:move_cursor((self:get_cursor() or 1) - 1)
        return ""
    end, expr)
    vim.keymap.set("i", "<Down>", function()
        if vim.fn.pumvisible() == 1 then return "<Down>" end
        self:move_cursor((self:get_cursor() or 0) + 1)
        return ""
    end, expr)
    vim.keymap.set("i", "<Up>", function()
        if vim.fn.pumvisible() == 1 then return "<Up>" end
        self:move_cursor((self:get_cursor() or 1) - 1)
        return ""
    end, expr)

    -- Half a page is Neovim's own <C-u>/<C-d> run in the list window. Setting
    -- the cursor alone would only ask Neovim to keep it visible, and its choice
    -- between pinning it near the top and re-centering it alternates at half a
    -- page. The row it lands on then goes back through `move_cursor`, which
    -- does not move it again but runs the marker, counter, preview and
    -- `on_cursor`.
    ---@param dir 1|-1
    ---@return fun()
    local function half_page(dir)
        return function()
            local win = self.lwin
            if not win or not vim.api.nvim_win_is_valid(win) then return end
            local before = self:get_cursor()
            if not before or #self.list_items == 0 then return end

            vim.api.nvim_win_call(win, function()
                vim.cmd("normal! " .. (dir > 0 and "\4" or "\21"))
            end)

            local row = self:get_cursor()
            if row and row ~= before then self:move_cursor(row, true, true) end
        end
    end

    vim.keymap.set({ "i", "n" }, "<C-d>", half_page(1), p)
    vim.keymap.set({ "i", "n" }, "<C-u>", half_page(-1), p)

    vim.keymap.set({ "i", "n" }, "<C-t>", function() self:toggle_preview() end, p)
    vim.keymap.set({ "i", "n" }, "<C-e>", function() self:toggle_expanded() end, p)
    vim.keymap.set({ "i", "n" }, "<C-l>", function() self:_cycle_focus() end, p)

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = self.pbuf,
        callback = function()
            local text = vim.api.nvim_buf_get_lines(self.pbuf, 0, 1, false)[1] or ""
            if text ~= self.query_text then
                self.query_text = text
                self:run_filter()
            end
        end,
    })

    local l = key_opts(self.lbuf)
    vim.keymap.set("n", "<Esc>", function() self:close() end, l)
    vim.keymap.set("n", "<CR>", function() self:confirm() end, l)
    vim.keymap.set("n", "<C-t>", function() self:toggle_preview() end, l)
    vim.keymap.set("n", "<C-e>", function() self:toggle_expanded() end, l)
    vim.keymap.set("n", "<C-l>", function() self:_cycle_focus() end, l)

    -- With the focus on the list, the cursor is moved by ordinary motions -- j,
    -- k, the mouse -- and not through `move_cursor`, so the marker and the
    -- counter have to follow the cursor it actually landed on.
    vim.api.nvim_create_autocmd("CursorMoved", {
        buffer   = self.lbuf,
        callback = function()
            if self.closed or not self.lbuf then return end
            self:_render_selection()
        end,
    })
end

-- Public API

---Open a floating fuzzy picker. `callback` receives the selected item's `data`
---(or the bare string for string items), or `nil` when cancelled.
---@param opts ndap.select.Opts
---@param callback fun(data:any?)
function M.open(opts, callback)
    assert(type(opts) == "table", "select.open: opts must be a table")
    assert(type(callback) == "function", "select.open: callback must be a function")
    Picker:new(opts, callback)
end

return M
