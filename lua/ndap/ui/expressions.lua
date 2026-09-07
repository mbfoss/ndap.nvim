---@brief Global watch-expression registry.
---Expressions are stored here independent of any session or UI.

local Signal = require("ndap.util.Signal")

---@class ndap.Expression
---@field internal_id integer
---@field expr        string

local M = {}

---Fires whenever the expression list changes.
M.on_change = Signal.new() ---@type ndap.util.Signal<fun()>

---@type ndap.Expression[]
local _expressions = {}

local _next_id = 1
local function _new_id()
    local id = _next_id
    _next_id = _next_id + 1
    return id
end

---@param expr string
---@return ndap.Expression?
function M.add(expr)
    local e = { internal_id = _new_id(), expr = expr }
    _expressions[#_expressions + 1] = e
    M.on_change:emit()
    return e
end

---@param id       integer  internal id
---@param new_expr string
---@return boolean
function M.update(id, new_expr)
    for _, e in ipairs(_expressions) do
        if e.internal_id == id then
            e.expr = new_expr
            M.on_change:emit()
            return true
        end
    end
    return false
end

---@param id integer  internal id
---@return boolean
function M.remove(id)
    for i, e in ipairs(_expressions) do
        if e.internal_id == id then
            table.remove(_expressions, i)
            M.on_change:emit()
            return true
        end
    end
    return false
end

---@return ndap.Expression[]
function M.all()
    return vim.list_extend({}, _expressions)
end

-- Persistence

---@return string[]
function M.get_data()
    return vim.tbl_map(function(e) return e.expr end, _expressions)
end

---@param data table|nil
function M.restore(data)
    _expressions = {}
    for _, expr in ipairs(type(data) == "table" and data or {}) do
        if type(expr) == "string" and expr ~= "" then
            _expressions[#_expressions + 1] = { internal_id = _new_id(), expr = expr }
        end
    end
    M.on_change:emit()
end

return M
