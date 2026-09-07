local M = {}

---@type table<string, fun(): vim.api.keyset.highlight>  -- themed group -> spec
local _specs = {}
local _augroup ---@type integer?

---Mix two 24-bit colours: `pct` percent of the way from `fg` to `bg`.
---@param fg integer
---@param bg integer
---@param pct integer
---@return integer
function M.mix(fg, bg, pct)
    local out = 0
    for _, scale in ipairs({ 65536, 256, 1 }) do
        local f, b = math.floor(fg / scale) % 256, math.floor(bg / scale) % 256
        out = out + math.floor(f + (b - f) * pct / 100 + 0.5) * scale
    end
    return out
end

---Convert a colour to a 24-bit integer: an integer passes through, and a `#rrggbb`
---string is parsed. Anything else raises.
---@param color integer|string
---@return integer
function M.normalize_color(color)
    if type(color) == "number" then return color end
    if type(color) == "string" then
        local n = tonumber((color:gsub("^#", "")), 16)
        if n then return n end
    end
    error("invalid color: " .. tostring(color))
end

---Linearly blend two 24-bit colours, `alpha` 0 giving `c1` and 1 giving `c2`.
---Either colour may be an integer or a `#rrggbb` string.
---@param c1 integer|string  -- base colour
---@param c2 integer|string  -- colour blended toward
---@param alpha number  -- 0 = all `c1`, 1 = all `c2`
---@return integer
function M.blend_colors(c1, c2, alpha)
    c1, c2 = M.normalize_color(c1), M.normalize_color(c2)
    local out = 0
    for _, scale in ipairs({ 65536, 256, 1 }) do
        local a, b = math.floor(c1 / scale) % 256, math.floor(c2 / scale) % 256
        out = out + math.floor(a * (1 - alpha) + b * alpha) * scale
    end
    return out
end

---The colour faded into: the background of `bg`, or black/white when it has none.
---@param bg string
---@return integer
local function _backdrop(bg)
    local hl = vim.api.nvim_get_hl(0, { name = bg, link = false })
    return hl.bg or (vim.o.background == "light" and 0xffffff or 0x000000)
end

---Highlight info for the text colour of `src` faded `pct` percent into the
---background of `bg`, `Normal` by default. Only the text colour is taken, so no
---block is painted behind the text; with `reverse` that is the one drawn as its
---background. `ctermfg` comes over unfaded. Links to `src` when it has no text
---colour.
---@param src string
---@param pct integer
---@param bg string?  -- group the background is taken from, default `Normal`
---@return vim.api.keyset.highlight
function M.faded_hl_info(src, pct, bg)
    local backdrop = _backdrop(bg or "Normal")
    local hl = vim.api.nvim_get_hl(0, { name = src, link = false })
    local fg, ctermfg = hl.fg, hl.ctermfg
    if hl.reverse then fg = hl.bg or backdrop end
    if hl.cterm and hl.cterm.reverse then ctermfg = hl.ctermbg end
    if not (fg or ctermfg) then return { link = src } end
    return {
        fg = fg and M.mix(fg, backdrop, math.min(pct, 100)) or nil,
        ctermfg = ctermfg,
    }
end

---@class ndap.util.color.CreateThemedHlOpts
---@field name string  -- group to define
---@field spec fun(): vim.api.keyset.highlight  -- evaluated now and on every colorscheme change

---Define `opts.name` from `opts.spec`, and redefine it on every colorscheme change.
---@param opts ndap.util.color.CreateThemedHlOpts
function M.create_themed_hl(opts)
    _specs[opts.name] = opts.spec
    vim.api.nvim_set_hl(0, opts.name, opts.spec())
    if not _augroup then
        _augroup = vim.api.nvim_create_augroup("NdapThemedHl", { clear = true })
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = _augroup,
            callback = function()
                for name, spec in pairs(_specs) do vim.api.nvim_set_hl(0, name, spec()) end
            end,
        })
    end
end

return M
