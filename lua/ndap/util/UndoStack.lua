---@brief A bounded undo/redo history.
---An entry is a group of steps that together make up one user action; undoing
---runs their `undo` in reverse order, redoing runs their `redo` forwards.

---@class ndap.util.UndoStack.Step
---@field undo fun()
---@field redo fun()

---@class ndap.util.UndoStack
---@field private _undone  ndap.util.UndoStack.Step[][]  entries that can be undone, oldest first
---@field private _redone  ndap.util.UndoStack.Step[][]  entries that can be redone, oldest first
---@field private _limit   integer
---@field private _open    ndap.util.UndoStack.Step[]?   group currently collecting pushes
local UndoStack = {}
UndoStack.__index = UndoStack

---@param limit integer?  max entries kept, oldest dropped first (default 50)
---@return ndap.util.UndoStack
function UndoStack.new(limit)
    return setmetatable({ _undone = {}, _redone = {}, _limit = limit or 50 }, UndoStack)
end

---Record an action that just happened, as the pair of callbacks that reverts it
---and replays it. Joins the open group if `group()` is running, otherwise
---becomes an entry of its own. Recording drops the redo history.
---@param undo fun()
---@param redo fun()
function UndoStack:push(undo, redo)
    self._redone = {}
    local step = { undo = undo, redo = redo }
    if self._open then
        self._open[#self._open + 1] = step
        return
    end
    self:_add(self._undone, { step })
end

---Run `fn` with a group open, so every `push()` it makes undoes and redoes as
---one action. Nothing is recorded if `fn` pushes nothing. Groups don't nest: a
---`group()` inside a `group()` keeps collecting into the outer one.
---@param fn fun()
function UndoStack:group(fn)
    if self._open then return fn() end
    local entry = {}
    self._open = entry
    local ok, err = pcall(fn)
    self._open = nil
    if #entry > 0 then self:_add(self._undone, entry) end
    if not ok then error(err, 0) end
end

---Revert the most recent entry, making it redoable.
---@return boolean  false if there was nothing to undo
function UndoStack:undo()
    local entry = table.remove(self._undone)
    if not entry then return false end
    for i = #entry, 1, -1 do
        entry[i].undo()
    end
    self:_add(self._redone, entry)
    return true
end

---Replay the most recently undone entry, making it undoable again.
---@return boolean  false if there was nothing to redo
function UndoStack:redo()
    local entry = table.remove(self._redone)
    if not entry then return false end
    for _, step in ipairs(entry) do
        step.redo()
    end
    self:_add(self._undone, entry)
    return true
end

function UndoStack:clear()
    self._undone = {}
    self._redone = {}
    self._open = nil
end

---@return boolean
function UndoStack:is_empty()
    return #self._undone == 0 and #self._redone == 0
end

---@private
---@param stack ndap.util.UndoStack.Step[][]
---@param entry ndap.util.UndoStack.Step[]
function UndoStack:_add(stack, entry)
    stack[#stack + 1] = entry
    if #stack > self._limit then table.remove(stack, 1) end
end

return UndoStack
