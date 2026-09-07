---@brief Builder for the plaintext detail blocks the hover floats are made of.
---Lines are assembled from aligned `label  value` rows, raw lines, multi-line
---text and comma lists wrapped to a column, then shown in a floating preview.

---@class ndap.ui.DetailBlock.Opts
---@field label_width? integer  column a `kv` value starts at (default 13)
---@field wrap_width?  integer  column `list` wraps at (default 72)
---@field focus_id?    string   float identity; a second show focuses it instead of stacking

---@class ndap.ui.DetailBlock
---@field private _lines    string[]
---@field private _label_w  integer
---@field private _wrap_w   integer
---@field private _focus_id string
local DetailBlock       = {}
DetailBlock.__index     = DetailBlock

local _DEFAULT_LABEL_W  = 13
local _DEFAULT_WRAP_W   = 72
local _DEFAULT_FOCUS_ID = "ndap_detail"

---@param opts ndap.ui.DetailBlock.Opts?
---@return ndap.ui.DetailBlock
function DetailBlock.new(opts)
    opts = opts or {}
    return setmetatable({
        _lines    = {},
        _label_w  = opts.label_width or _DEFAULT_LABEL_W,
        _wrap_w   = opts.wrap_width or _DEFAULT_WRAP_W,
        _focus_id = opts.focus_id or _DEFAULT_FOCUS_ID,
    }, DetailBlock)
end

---Append one line verbatim. Nil and the empty string are skipped: a deliberate
---separator is `blank`.
---@param text string|number|nil
---@return ndap.ui.DetailBlock self
function DetailBlock:line(text)
    if type(text) ~= "string" and type(text) ~= "number" then return self end
    if text == "" then return self end
    self._lines[#self._lines + 1] = tostring(text)
    return self
end

---Append a `label  value` row, the value aligned at the block's label column.
---Anything but a non-empty string or number is skipped, so optional fields can
---be passed straight through.
---@param label string
---@param value string|number|nil
---@return ndap.ui.DetailBlock self
function DetailBlock:kv(label, value)
    if type(value) ~= "string" and type(value) ~= "number" then return self end
    if value == "" then return self end
    self._lines[#self._lines + 1] = ("%-" .. self._label_w .. "s%s"):format(label, value)
    return self
end

---Append a separator. No-op at the start of the block or after another blank,
---so callers can prefix every section with one.
---@return ndap.ui.DetailBlock self
function DetailBlock:blank()
    local n = #self._lines
    if n == 0 or self._lines[n] == "" then return self end
    self._lines[n + 1] = ""
    return self
end

---Append a blank-separated header line.
---@param title string
---@return ndap.ui.DetailBlock self
function DetailBlock:section(title)
    return self:blank():line(title)
end

---Append multi-line text, one line per newline, blank lines preserved.
---@param text string?
---@param indent string?  prefix for every line (default none)
---@return ndap.ui.DetailBlock self
function DetailBlock:text(text, indent)
    if type(text) ~= "string" or text == "" then return self end
    for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
        self._lines[#self._lines + 1] = (indent or "") .. l
    end
    return self
end

---Append `items` as a comma-separated list, wrapped at the block's wrap width.
---@param items (string|number)[]
---@param indent string?  prefix for every line (default two spaces)
---@return ndap.ui.DetailBlock self
function DetailBlock:list(items, indent)
    indent = indent or "  "
    local cur = ""
    for _, item in ipairs(items) do
        local piece = (cur == "") and tostring(item) or (cur .. ", " .. item)
        if cur ~= "" and vim.fn.strdisplaywidth(indent .. piece) > self._wrap_w then
            self._lines[#self._lines + 1] = indent .. cur .. ","
            cur = tostring(item)
        else
            cur = piece
        end
    end
    if cur ~= "" then self._lines[#self._lines + 1] = indent .. cur end
    return self
end

---@return boolean
function DetailBlock:is_empty()
    return #self._lines == 0 or self._lines[1] == ""
end

---@return string[]
function DetailBlock:lines()
    return self._lines
end

---Show the block in an LSP-style floating preview. Nothing is opened for an
---empty block, so a caller that found nothing to report can just show it.
---@param title string?
---@return integer? bufnr, integer? winid
function DetailBlock:show(title)
    if self:is_empty() then return end
    return vim.lsp.util.open_floating_preview(self._lines, "plaintext", {
        border   = "rounded",
        title    = title,
        focus_id = self._focus_id,
    })
end

return DetailBlock
