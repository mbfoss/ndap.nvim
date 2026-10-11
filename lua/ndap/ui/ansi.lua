---@brief Minimal ANSI SGR parser.
---Turns a chunk of text carrying CSI SGR escape sequences (colors/attributes)
---into clean, escape-free text plus a list of highlight spans over its byte
---columns. Non-SGR CSI sequences (cursor moves, erase-line, …) are stripped
---without effect. SGR state is threaded by the caller across chunks/lines, as a
---terminal would, so a colour opened on one line stays open on the next.

local M = {}

---@class ndap.ui.ansi.State
---@field fg        integer|string|nil  palette index (0-255) or "#rrggbb"
---@field bg        integer|string|nil
---@field bold      boolean?
---@field dim       boolean?
---@field italic    boolean?
---@field underline boolean?
---@field reverse   boolean?

---@class ndap.ui.ansi.Span
---@field s  integer  start byte column (0-based, inclusive)
---@field e  integer  end byte column (0-based, exclusive)
---@field hl string   highlight group name

-- Fallback for the first 16 colours, used only where the colorscheme has not
-- set the matching `g:terminal_color_N`.
local _palette16 = {
    [0] = "#000000", [1] = "#cd0000", [2] = "#00cd00", [3] = "#cdcd00",
    [4] = "#0000ee", [5] = "#cd00cd", [6] = "#00cdcd", [7] = "#e5e5e5",
    [8] = "#7f7f7f", [9] = "#ff0000", [10] = "#00ff00", [11] = "#ffff00",
    [12] = "#5c5cff", [13] = "#ff00ff", [14] = "#00ffff", [15] = "#ffffff",
}

local _hl_cache = {}   -- state key -> highlight group name
local _hl_defs  = {}   -- highlight group name -> the state it renders
local _next_id  = 0

---@return ndap.ui.ansi.State
function M.new_state()
    return {}
end

---@param state ndap.ui.ansi.State
local function reset(state)
    state.fg, state.bg = nil, nil
    state.bold, state.dim, state.italic, state.underline, state.reverse = nil, nil, nil, nil, nil
end

---Resolve an xterm 256-colour index to a "#rrggbb" string.
---@param n integer
---@return string
local function xterm256(n)
    if n < 16 then
        -- Prefer the colorscheme's terminal palette so ANSI output matches the
        -- rest of the UI; `g:terminal_color_N` is what :terminal itself uses.
        local c = vim.g["terminal_color_" .. n]
        return type(c) == "string" and c or _palette16[n]
    end
    if n >= 232 then
        local v = 8 + (n - 232) * 10
        return string.format("#%02x%02x%02x", v, v, v)
    end
    n = n - 16
    local r, g, b = math.floor(n / 36), math.floor((n % 36) / 6), n % 6
    local function c(x) return x == 0 and 0 or 55 + x * 40 end
    return string.format("#%02x%02x%02x", c(r), c(g), c(b))
end

---@param color integer|string
---@return string
local function to_hex(color)
    if type(color) == "string" then return color end
    return xterm256(color)
end

---Read a 38/48 extended-colour sequence starting at `idx` (the 38/48 code).
---@param codes integer[]
---@param idx integer
---@return integer new_idx  index of the last consumed code
---@return integer|string|nil color
local function read_extended(codes, idx)
    local mode = codes[idx + 1]
    if mode == 5 then
        return idx + 2, codes[idx + 2]
    elseif mode == 2 then
        local r, g, b = codes[idx + 2], codes[idx + 3], codes[idx + 4]
        return idx + 4, string.format("#%02x%02x%02x", r or 0, g or 0, b or 0)
    end
    return idx + 1, nil
end

---Apply an SGR parameter string (the text between CSI and the `m`) to `state`.
---@param state ndap.ui.ansi.State
---@param params string
local function apply_sgr(state, params)
    local codes = {}
    for c in params:gmatch("%d+") do codes[#codes + 1] = tonumber(c) end
    if #codes == 0 then codes = { 0 } end

    local idx = 1
    while idx <= #codes do
        local c = codes[idx]
        if c == 0 then reset(state)
        elseif c == 1 then state.bold = true
        elseif c == 2 then state.dim = true
        elseif c == 3 then state.italic = true
        elseif c == 4 then state.underline = true
        elseif c == 7 then state.reverse = true
        elseif c == 22 then state.bold, state.dim = nil, nil
        elseif c == 23 then state.italic = nil
        elseif c == 24 then state.underline = nil
        elseif c == 27 then state.reverse = nil
        elseif c >= 30 and c <= 37 then state.fg = c - 30
        elseif c == 38 then idx, state.fg = read_extended(codes, idx)
        elseif c == 39 then state.fg = nil
        elseif c >= 40 and c <= 47 then state.bg = c - 40
        elseif c == 48 then idx, state.bg = read_extended(codes, idx)
        elseif c == 49 then state.bg = nil
        elseif c >= 90 and c <= 97 then state.fg = c - 90 + 8
        elseif c >= 100 and c <= 107 then state.bg = c - 100 + 8
        end
        idx = idx + 1
    end
end

---@param state ndap.ui.ansi.State
---@return boolean
local function is_default(state)
    return not (state.fg or state.bg or state.bold or state.dim
        or state.italic or state.underline or state.reverse)
end

---(Re)define `name` from `state`, resolving palette indices against the current
---colorscheme.
---@param name string
---@param state ndap.ui.ansi.State
local function define(name, state)
    local opts = {}
    if state.fg ~= nil then opts.fg = to_hex(state.fg) end
    if state.bg ~= nil then opts.bg = to_hex(state.bg) end
    if state.bold then opts.bold = true end
    if state.italic then opts.italic = true end
    if state.underline then opts.underline = true end
    if state.reverse then opts.reverse = true end
    vim.api.nvim_set_hl(0, name, opts)
end

---Highlight group for the current state, defining it on first use. Returns nil
---for the default (unstyled) state, so plain text gets no extmark.
---@param state ndap.ui.ansi.State
---@return string?
function M.hl_for(state)
    if is_default(state) then return nil end

    local key = table.concat({
        tostring(state.fg), tostring(state.bg),
        state.bold and "b" or "", state.dim and "d" or "",
        state.italic and "i" or "", state.underline and "u" or "",
        state.reverse and "r" or "",
    }, "|")

    local name = _hl_cache[key]
    if name then return name end

    name = "NdapAnsi_" .. _next_id
    _next_id = _next_id + 1

    _hl_cache[key] = name
    _hl_defs[name] = vim.deepcopy(state)
    define(name, state)
    return name
end

-- Palette indices resolve against the active colorscheme, so every group has to
-- be re-resolved when that changes; the names stay put, keeping live extmarks
-- valid.
vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("NdapAnsi", { clear = true }),
    callback = function()
        for name, state in pairs(_hl_defs) do define(name, state) end
    end,
})

---Parse `text` (a single line, no newlines) into clean text and highlight
---spans, threading `state` through so styles carry across calls.
---@param state ndap.ui.ansi.State
---@param text string
---@return string clean
---@return ndap.ui.ansi.Span[] spans
function M.parse(state, text)
    local clean = {}
    local spans = {}
    local col = 0
    local span_start = 0
    local cur_hl = M.hl_for(state)

    ---@param upto integer  end column of the run, exclusive
    local function flush(upto)
        if cur_hl and upto > span_start then
            spans[#spans + 1] = { s = span_start, e = upto, hl = cur_hl }
        end
        span_start = upto
    end

    local i, n = 1, #text
    while i <= n do
        local s, e, params, final = text:find("\27%[([%d;?]*)(%a)", i)
        if not s then
            local chunk = text:sub(i)
            clean[#clean + 1] = chunk
            col = col + #chunk
            break
        end
        if s > i then
            local chunk = text:sub(i, s - 1)
            clean[#clean + 1] = chunk
            col = col + #chunk
        end
        if final == "m" then
            flush(col)
            apply_sgr(state, params)
            cur_hl = M.hl_for(state)
        end
        i = e + 1
    end
    flush(col)

    return table.concat(clean), spans
end

return M
