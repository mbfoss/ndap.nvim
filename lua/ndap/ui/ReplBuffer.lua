local ui = require "ndap.util.ui"
---@brief DAP REPL buffer.
---Uses nvim_open_term to render a prompt-driven REPL with history, cursor
---movement, async evaluation, and Tab completion with cycling.
---
---Result output is printed above the prompt, so the user can keep typing
---the next expression while the previous one is evaluating.

local _RESET  = "\27[0m"
local _BOLD   = "\27[1m"
local _DIM    = "\27[2m"
local _GREEN  = "\27[32m"
local _CYAN   = "\27[36m"
local _RED    = "\27[31m"
local _PROMPT = _BOLD .. _GREEN .. "» " .. _RESET
local _PROMPT_W = 2   -- visual width of "» "

-- Grid formatter

---Lay `items` out in columns that fit `width`, joined by CRLF for the terminal.
---@param items string[]
---@param width integer?   default 80
---@return string
local function _format_grid(items, width)
    width = width or 80
    local max_len = 0
    for _, s in ipairs(items) do if #s > max_len then max_len = #s end end
    local col_w  = max_len + 2
    local n_cols = math.max(1, math.floor(width / col_w))
    local rows   = {}
    local row    = {}
    for i, s in ipairs(items) do
        row[#row + 1] = s .. string.rep(" ", col_w - #s)
        if i % n_cols == 0 then
            rows[#rows + 1] = table.concat(row):gsub("%s+$", "")
            row = {}
        end
    end
    if #row > 0 then rows[#rows + 1] = table.concat(row):gsub("%s+$", "") end
    return table.concat(rows, "\r\n")
end

-- Class

---@class ndap.ReplBuffer
---@field private _bufnr    integer
---@field private _chan     integer
---@field private _line     string    current input
---@field private _cursor   integer   1-based (1 = before first char)
---@field private _history  string[]
---@field private _hist_idx integer   0 = not navigating
---@field private _evaluate fun(expr:string, cb:fun(result:string?, err:string?))
---@field private _complete (fun(text:string, col:integer, cb:fun(targets:table[])))?
---@field private _disabled boolean   drop input: the session behind this REPL is gone
---@field private _compl    ndap.ReplBuffer.ComplState
local ReplBuffer = {}
ReplBuffer.__index = ReplBuffer

---@class ndap.ReplBuffer.ComplState
---@field req      integer   in-flight request counter
---@field cycle    string[]  candidates to cycle through
---@field idx      integer   current cycle position (0 = not yet cycled)
---@field left     string    line left of cursor when Tab was pressed
---@field right    string    line right of cursor when Tab was pressed
---@field grid     boolean   whether the grid has been shown

---@class ndap.ReplBuffer.Opts
---@field name     string
---@field evaluate fun(expr:string, cb:fun(result:string?, err:string?))
---@field complete? fun(text:string, col:integer, cb:fun(targets:table[]))

---@param opts ndap.ReplBuffer.Opts
---@return ndap.ReplBuffer
function ReplBuffer.new(opts)
    ---@type ndap.ReplBuffer.ComplState
    local compl = { req = 0, cycle = {}, idx = 0, left = "", right = "", grid = false }
    local self = setmetatable({
        _line      = "",
        _cursor    = 1,
        _history   = {},
        _hist_idx  = 0,
        _evaluate  = opts.evaluate,
        _complete  = opts.complete,
        _chan      = nil,
        _bufnr     = nil,
        _disabled  = false,
        _compl     = compl,
    }, ReplBuffer)
    self:_init(opts.name)
    return self
end

-- Initialisation

---@param name string  buffer name
function ReplBuffer:_init(name)
    self._bufnr = ui.create_scratch_buffer(true, {
        bufhidden = "hide",
        spelloptions = "noplainbuffer",
    }, function()
        self._bufnr = -1
    end)

    local buf =  self._bufnr
    vim.api.nvim_buf_set_name(buf, name)

    self._chan = vim.api.nvim_open_term(buf, {
        on_input = function(_, _, _, data)
            vim.schedule(function() self:_handle(data) end)
        end,
    })

    vim.keymap.set("t", "<Esc>", "<C-\\><C-n>", { buffer = buf, desc = "Exit terminal mode" })
    vim.api.nvim_chan_send(self._chan, _PROMPT)
end

---@return integer
function ReplBuffer:bufnr()
    return self._bufnr
end

---Stop accepting input: the session behind this REPL has ended. Remaining
---output stays readable, but keys are dropped instead of being evaluated.
---@param notice? string  printed in place of the prompt
function ReplBuffer:disable(notice)
    if self._disabled or not vim.api.nvim_buf_is_valid(self._bufnr) then return end
    self._disabled = true
    self:_reset_compl()
    self._line     = ""
    self._cursor   = 1
    vim.api.nvim_chan_send(self._chan,
        "\r\27[K" .. _DIM .. "-- " .. (notice or "session ended") .. " --" .. _RESET .. "\r\n")
end

-- Helpers

---Width of the window displaying this buffer, fallback 80.
function ReplBuffer:_width()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(win) == self._bufnr then
            return vim.api.nvim_win_get_width(win) - 1
        end
    end
    return 80
end

function ReplBuffer:_reset_compl()
    local c = self._compl
    c.cycle = {}
    c.idx   = 0
    c.left  = ""
    c.right = ""
    c.grid  = false
end

-- Rendering

function ReplBuffer:_redraw()
    if self._disabled then return end
    local col = _PROMPT_W + self._cursor
    vim.api.nvim_chan_send(self._chan,
        "\r\27[K" .. _PROMPT .. self._line .. "\27[" .. col .. "G")
end

---Print a single line of output above the prompt (internal, no CRLF normalisation).
---@param text string  may contain ANSI codes
function ReplBuffer:_print(text)
    vim.api.nvim_chan_send(self._chan, "\r\27[K" .. text .. "\r\n")
    self:_redraw()
end

---Write debugger output text above the current prompt.
---Handles multi-line text and CRLF normalisation in one send.
---@param text string
function ReplBuffer:write(text)
    if not vim.api.nvim_buf_is_valid(self._bufnr) then return end
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    if text:sub(-1) == "\n" then text = text:sub(1, -2) end
    if text == "" then return end
    -- clear each line before printing, advance with CRLF
    vim.api.nvim_chan_send(self._chan,
        "\r\27[K" .. text:gsub("\n", "\r\n\27[K") .. "\r\n")
    self:_redraw()
end

-- Evaluation

---@param expr string  the expression to evaluate and print
function ReplBuffer:_submit(expr)
    self._evaluate(expr, function(result, err)
        vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(self._bufnr) then return end
            if err or not result then
                self:_print(_BOLD .. _RED .. "✗ " .. _RESET .. (err or "not available"))
            else
                local lines = vim.split(result, "\n", { plain = true })
                if lines[#lines] == "" then table.remove(lines) end
                for i, line in ipairs(lines) do
                    local prefix = i == 1 and (_BOLD .. _CYAN .. "= " .. _RESET) or "  "
                    self:_print(prefix .. line)
                end
            end
        end)
    end)
end

-- Completion

function ReplBuffer:_cycle_next()
    local c = self._compl
    if #c.cycle == 0 then return end

    c.idx = c.idx % #c.cycle + 1
    local suggestion = c.cycle[c.idx]

    -- Replace the last token before the cursor with the suggestion,
    -- keeping any prefix of words that precede it intact.
    local new_left
    if c.left == "" or suggestion:sub(1, #c.left) == c.left then
        new_left = suggestion
    else
        local prefix = c.left:match("^(.-)%S*$") or ""
        new_left = prefix .. suggestion
    end

    self._line   = new_left .. c.right
    self._cursor = #new_left + 1
    self:_redraw()
end

function ReplBuffer:_handle_tab()
    if not self._complete then return end

    local c = self._compl

    -- Already have candidates: just cycle
    if #c.cycle > 0 and c.grid then
        self:_cycle_next()
        return
    end

    local left   = self._line:sub(1, self._cursor - 1)
    local right  = self._line:sub(self._cursor)
    local req_id = c.req + 1
    c.req        = req_id

    self._complete(left, #left + 1, function(targets)
        vim.schedule(function()
            -- Discard if a newer request fired or the context changed
            if req_id ~= self._compl.req then return end
            if self._line:sub(1, self._cursor - 1) ~= left then return end

            local items = {}
            for _, t in ipairs(targets) do
                local s = t.text or t.label
                if s and s ~= "" then items[#items + 1] = s end
            end
            if #items == 0 then return end

            c.cycle = items
            c.left  = left
            c.right = right
            c.idx   = 0

            if #items == 1 then
                self:_cycle_next()
            else
                self:_print(_RESET .. _format_grid(items, self:_width()) .. _RESET)
                c.grid = true
                self:_cycle_next()
            end
        end)
    end)
end

-- Input state machine

---@param data string  key sequence received from the terminal channel
function ReplBuffer:_handle(data)
    -- The session is gone: swallow keys rather than evaluating against whatever
    -- session happens to be active.
    if self._disabled then return end

    -- Tab: completion (handled before cycle reset)
    if data == "\t" then
        self:_handle_tab()
        return
    end

    -- All other keys reset the completion cycle
    self:_reset_compl()

    -- Ctrl-C: cancel current line
    if data == "\3" then
        self:_print(_DIM .. "^C" .. _RESET)
        self._line     = ""
        self._cursor   = 1
        self._hist_idx = 0
        return
    end

    -- Ctrl-L: clear screen
    if data == "\12" then
        vim.api.nvim_chan_send(self._chan, "\27[2J\27[H")
        self:_redraw()
        return
    end

    -- Ctrl-A: beginning of line
    if data == "\1" then
        self._cursor = 1
        self:_redraw()
        return
    end

    -- Ctrl-E: end of line
    if data == "\5" then
        self._cursor = #self._line + 1
        self:_redraw()
        return
    end

    -- Ctrl-W: delete word before cursor
    if data == "\23" then
        local left     = self._line:sub(1, self._cursor - 1)
        local right    = self._line:sub(self._cursor)
        local new_left = left:gsub("%s*%S+%s*$", "")
        self._line   = new_left .. right
        self._cursor = #new_left + 1
        self:_redraw()
        return
    end

    -- Ctrl-U: delete to beginning
    if data == "\21" then
        self._line   = self._line:sub(self._cursor)
        self._cursor = 1
        self:_redraw()
        return
    end

    -- Ctrl-K: delete to end
    if data == "\11" then
        self._line = self._line:sub(1, self._cursor - 1)
        self:_redraw()
        return
    end

    -- Enter
    if data == "\r" or data == "\n" then
        local expr = self._line
        vim.api.nvim_chan_send(self._chan, "\r\n")
        self._line     = ""
        self._cursor   = 1
        self._hist_idx = 0
        if expr ~= "" then
            if self._history[#self._history] ~= expr then
                self._history[#self._history + 1] = expr
                if #self._history > 200 then table.remove(self._history, 1) end
            end
            self:_redraw()
            self:_submit(expr)
        else
            self:_redraw()
        end
        return
    end

    -- Up / Ctrl-P: history prev
    if data == "\27[A" or data == "\16" then
        if #self._history == 0 then return end
        self._hist_idx = self._hist_idx == 0
            and #self._history or math.max(1, self._hist_idx - 1)
        self._line   = self._history[self._hist_idx]
        self._cursor = #self._line + 1
        self:_redraw()
        return
    end

    -- Down / Ctrl-N: history next
    if data == "\27[B" or data == "\14" then
        if self._hist_idx == 0 then return end
        if self._hist_idx < #self._history then
            self._hist_idx = self._hist_idx + 1
            self._line = self._history[self._hist_idx]
        else
            self._hist_idx = 0
            self._line = ""
        end
        self._cursor = #self._line + 1
        self:_redraw()
        return
    end

    -- Left
    if data == "\27[D" then
        if self._cursor > 1 then self._cursor = self._cursor - 1 end
        self:_redraw()
        return
    end

    -- Right
    if data == "\27[C" then
        if self._cursor <= #self._line then self._cursor = self._cursor + 1 end
        self:_redraw()
        return
    end

    -- Home
    if data == "\27[H" or data == "\27[1~" then
        self._cursor = 1
        self:_redraw()
        return
    end

    -- End
    if data == "\27[F" or data == "\27[4~" then
        self._cursor = #self._line + 1
        self:_redraw()
        return
    end

    -- Delete (forward)
    if data == "\27[3~" then
        if self._cursor <= #self._line then
            self._line = self._line:sub(1, self._cursor - 1)
                .. self._line:sub(self._cursor + 1)
            self:_redraw()
        end
        return
    end

    -- Backspace
    if data == "\127" or data == "\8" then
        if self._cursor > 1 then
            self._line   = self._line:sub(1, self._cursor - 2)
                .. self._line:sub(self._cursor)
            self._cursor = self._cursor - 1
            self:_redraw()
        end
        return
    end

    -- Ignore unrecognised escape sequences
    if data:find("^\27") then return end

    -- Printable character(s)
    self._line   = self._line:sub(1, self._cursor - 1)
        .. data
        .. self._line:sub(self._cursor)
    self._cursor = self._cursor + #data
    self:_redraw()
end

return ReplBuffer
