---@brief The full-value hover: an evaluated expression's type above its
---untruncated value, in a floating preview. Independent of any view: it is what
---`K` shows on a DebugView/InspectView node and what `:Ndap value` shows for an
---expression, so all three render through here.

local DetailBlock = require("ndap.ui.DetailBlock")
local manager     = require("ndap.manager")

local M           = {}

---@class ndap.ui.value_hover.Value
---@field name   string   float title
---@field value  string?  the value, shown in full
---@field type   string?  declared type, shown above the value when known

---@class ndap.ui.value_hover.Opts
---@field focus_id? string   float identity; a second show reuses it instead of stacking (default "ndap_value")
---@field focus?    boolean  move the cursor into the float once open (default false)
---@field title?    string   `evaluate` only: float title, when the row's name reads better than the expression

---Show a value hover. An absent value renders as "not available", so a failed
---evaluation goes through the same call with its error as the value.
---@param value ndap.ui.value_hover.Value
---@param opts? ndap.ui.value_hover.Opts
---@return integer? win
function M.show(value, opts)
    opts = opts or {}
    local block = DetailBlock.new({ focus_id = opts.focus_id or "ndap_value" })
    if value.type and value.type ~= "" then
        block:line(value.type):blank()
    end
    block:text(value.value or "")
    if block:is_empty() then block:line("not available") end

    -- open_floating_preview opens the float unfocused; its close autocmds ignore
    -- its own buffer, so entering it doesn't dismiss it.
    local win = select(2, block:show(value.name))
    if win and opts.focus then vim.api.nvim_set_current_win(win) end
    return win
end

---Evaluate `expr` in the active session and show its value. A missing session is
---a notification; an adapter error is shown in the float itself, where the value
---the caller asked for would have been. A reply that arrives after the session
---moved on is discarded.
---@param expr string
---@param opts? ndap.ui.value_hover.Opts
function M.evaluate(expr, opts)
    if not expr or expr == "" then
        vim.notify("[dap] nothing to inspect", vim.log.levels.WARN)
        return
    end
    if not manager.session() then
        vim.notify("[dap] no active session", vim.log.levels.WARN)
        return
    end
    local title = (opts and opts.title) or expr
    local context = manager.context_id()
    manager.evaluate(expr, "hover", function(body, err)
        if manager.context_id() ~= context then return end
        if err or not body then
            M.show({ name = title, value = err or "not available" }, opts)
        else
            M.show({ name = title, value = body.result, type = body.type }, opts)
        end
    end)
end

return M
