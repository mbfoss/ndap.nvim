local TreeBuffer    = require("ndap.util.TreeBuffer")
local node_details  = require("ndap.ui.node_details")
local manager       = require("ndap.manager")
local config        = require("ndap.config").current
local expressions   = require("ndap.ui.expressions")
local breakpoints   = require("ndap.dap.breakpoints")
local format        = require("ndap.ui.format")
local inputwin      = require("ndap.util.inputwin")
local select        = require("ndap.util.select")
local timer         = require("ndap.util.timer")
local hover         = require("ndap.util.hover")
local fixedwin      = require("ndap.util.fixedwin")
local ui            = require("ndap.util.ui")
local UndoStack     = require("ndap.util.UndoStack")

---@alias ndap.DebugView.ItemKind
---| "root"
---| "session"
---| "stackframe"
---| "scope"
---| "variable"
---| "expression"
---| "breakpoint"

---@class ndap.DebugView.ItemData
---@field kind     ndap.DebugView.ItemKind
---@field path     string
---@field name     string
---@field value    string?
---@field variablesReference number?
---@field evaluateName string?
---@field is_na    boolean?
---@field error    string?
---@field greyout  boolean?
---@field session_id number?
---@field session_info ndap.client.SessionInfo?
---@field is_current boolean?
---@field frame_id     integer?
---@field frame_source string?
---@field frame_line   integer?
---@field frame_column integer?
---@field bp_kind       ("source"|"function"|"exception_filter"|"exception_type"|"data")?
---@field bp_id         integer?
---@field bp_source     string?
---@field bp_line       integer?
---@field bp_column     integer?
---@field bp_filter     string?
---@field bp_ex_name    string?
---@field bp_data_id    string?
---@field access_type   string?
---@field break_mode    string?
---@field unsupported   boolean?
---@field disabled      boolean?
---@field verified      boolean?
---@field condition     string?
---@field hit_condition string?
---@field log_message   string?

---@alias ndap.DebugView.Chunk ndap.ui.Chunk

local _win_setlocal = ui.win_setlocal

---@param stop fun()?  stop fn returned by `_start_timer`, or nil
---@return nil
local function _cancel_timer(stop)
    if stop then stop() end
    return nil
end

---@param delay integer  milliseconds
---@param fn    fun()
---@return fun()  stop  stops and closes the timer
local function _start_timer(delay, fn)
    return timer.defer(delay, fn)
end

---@type { sessions: string, stack: string, variables: string, expressions: string, breakpoints: string }
local _roots = {
    sessions    = "sess",
    stack       = "stack",
    variables   = "vars",
    expressions = "xpr",
    breakpoints = "bps",
}

---Remove a watch expression by its text, the identity the tree shows. Ids don't
---survive a remove/re-add, so undo/redo has to match on the text.
---@param text string
---@return boolean
local function _remove_expression(text)
    for _, e in ipairs(expressions.all()) do
        if e.expr == text then return expressions.remove(e.internal_id) end
    end
    return false
end

-- Formatters

---@param data ndap.DebugView.ItemData
---@param chunks ndap.DebugView.Chunk[]
local function _fmt_root(data, chunks)
    chunks[#chunks + 1] = { data.name, "Title" }
end

---@param data ndap.DebugView.ItemData
---@param chunks ndap.DebugView.Chunk[]
local function _fmt_session(data, chunks)
    local info = data.session_info
    if not info then return end
    local icon, hl      = format.session_symbol(info)
    chunks[#chunks + 1] = { icon, hl }
    chunks[#chunks + 1] = { " ", nil }
    chunks[#chunks + 1] = { data.name, data.is_current and "Special" or nil }
    if info.state and info.state ~= "running" then
        chunks[#chunks + 1] = { " [" .. format.session_state(info.state) .. "]", "Tag" }
        if info.is_paused and info.state_reason then
            chunks[#chunks + 1] = { " (" .. info.state_reason .. ")", "Comment" }
        end
    end
end

---@param data ndap.DebugView.ItemData
---@param chunks ndap.DebugView.Chunk[]
local function _fmt_stackframe(data, chunks)
    local hl = data.greyout and "NonText" or (data.is_current and "Special" or nil)
    chunks[#chunks + 1] = { data.name, hl }
end

---@param data ndap.DebugView.ItemData
---@param chunks ndap.DebugView.Chunk[]
local function _fmt_scope(data, chunks)
    chunks[#chunks + 1] = { data.name, "@module" }
end

---@param data ndap.DebugView.ItemData
---@param chunks ndap.DebugView.Chunk[]
local function _fmt_variable(data, chunks)
    local hl = data.greyout and "NonText" or nil
    chunks[#chunks + 1] = { data.name, hl }
    chunks[#chunks + 1] = { ": ", hl}
    chunks[#chunks + 1] = { format.oneline(data.value), hl or "@string" }
end

---@param data ndap.DebugView.ItemData
---@param chunks ndap.DebugView.Chunk[]
local function _fmt_expression(data, chunks)
    chunks[#chunks + 1] = { data.name }
    chunks[#chunks + 1] = { " = ", "NonText" }
    chunks[#chunks + 1] = {
        format.oneline(data.value),
        (data.is_na or data.greyout) and "NonText" or "@string",
    }
end

---@param data ndap.DebugView.ItemData
---@param chunks ndap.DebugView.Chunk[]
local function _fmt_breakpoint(data, chunks)
    local icon, hl      = format.breakpoint_symbol({
        kind          = data.bp_kind,
        disabled      = data.disabled,
        verified      = data.verified,
        condition     = data.condition,
        hit_condition = data.hit_condition,
        log_message   = data.log_message,
        unsupported   = data.unsupported,
    }, true)
    chunks[#chunks + 1] = { icon .. " ", hl }
    local name_hl       = data.disabled and "NonText" or nil

    if data.bp_kind == "exception_type" and data.unsupported then
        chunks[#chunks + 1] = { data.name, name_hl }
        chunks[#chunks + 1] = { "  [unsupported]", "DiagnosticWarn" }
    elseif data.bp_kind == "exception_type" then
        chunks[#chunks + 1] = { data.name, name_hl }
        if data.break_mode then
            chunks[#chunks + 1] = { " [" .. data.break_mode .. "]", "Comment" }
        end
    elseif data.bp_kind == "function" then
        chunks[#chunks + 1] = { data.name, name_hl }
        chunks[#chunks + 1] = { " [fn]", "Comment" }
    elseif data.bp_kind == "data" then
        chunks[#chunks + 1] = { data.name, name_hl }
        if data.access_type then
            chunks[#chunks + 1] = { " [" .. data.access_type .. "]", "Comment" }
        end
    else
        -- Source breakpoint: the whole path, then the condition/logpoint suffix.
        chunks[#chunks + 1] = { data.name, name_hl }
        if data.condition then
            chunks[#chunks + 1] = { " if: " .. data.condition, "Comment" }
        end
        if data.hit_condition then
            chunks[#chunks + 1] = { " hit: " .. data.hit_condition, "Comment" }
        end
        if data.log_message then
            chunks[#chunks + 1] = { " log: " .. data.log_message, "Comment" }
        end
    end
end

---@type table<ndap.DebugView.ItemKind, fun(data: ndap.DebugView.ItemData, chunks: ndap.DebugView.Chunk[])>
local _formatters = {
    root       = _fmt_root,
    session    = _fmt_session,
    stackframe = _fmt_stackframe,
    scope      = _fmt_scope,
    variable   = _fmt_variable,
    expression = _fmt_expression,
    breakpoint = _fmt_breakpoint,
}

---@param data ndap.DebugView.ItemData?
---@return ndap.DebugView.Chunk[], table
local function _node_formatter(data)
    if not data then return {}, {} end
    local chunks = {}
    local fmt = _formatters[data.kind]
    if fmt then fmt(data, chunks) end
    return chunks, {}
end

-- DebugView class

---@class ndap.DebugView
---@field private _tree             ndap.util.TreeBuffer
---@field private _width_ratio      number?   last-known width ratio, reused on the next open
---@field private _active_id        number?
---@field private _active_sess      ndap.dap.Session?
---@field private _query_ctx        number
---@field private _subs             fun()[]
---@field private _expanded         table<string,boolean>
---@field private _greyout_timer    fun()?
---@field private _session_timer    fun()?
---@field private _undo             ndap.util.UndoStack
local DebugView = {}
DebugView.__index = DebugView

---@return ndap.DebugView
function DebugView.new()
    local self = setmetatable({
        _active_id   = nil,
        _active_sess = nil,
        _query_ctx   = 0,
        _subs        = {},
        _expanded    = {},
        _undo        = UndoStack.new(),
    }, DebugView)
    self:init()
    return self
end

function DebugView:init()
    self:_init_tree()
    self:_setup_subs()
    self:_load_breakpoints()
    return self
end

-- Tree init

---@private
function DebugView:_init_tree()
    self._tree = TreeBuffer.new({
        filetype  = "ndap-view",
        formatter = function(_, data)
            return _node_formatter(data)
        end,
    })

    ---@param id string
    ---@param name string
    local function root(id, name)
        self._tree:add_item(nil, {
            id         = id,
            expandable = true,
            expanded   = true,
            data       = { kind = "root", path = id, name = name },
        })
    end

    root(_roots.sessions, "Sessions")
    root(_roots.stack, "Call Stack")
    root(_roots.variables, "Variables")
    root(_roots.expressions, "Expressions")
    root(_roots.breakpoints, "Breakpoints")

    self._tree:subscribe({
        on_toggle = function(id, data, expanded)
            if data and data.path then
                self._expanded[data.path] = expanded
            end
            if not expanded then return end
            local ctx = self._query_ctx
            if id == _roots.stack then
                if self._active_sess then self:_load_stack(ctx) end
            elseif id == _roots.variables then
                if self._active_sess then self:_load_vars(ctx) end
            elseif id == _roots.expressions then
                self:_load_expressions(ctx)
            elseif id == _roots.breakpoints then
                self:_load_breakpoints()
            elseif data and (data.kind == "scope" or data.kind == "variable" or data.kind == "expression") then
                local ref = data.variablesReference
                if ref and ref > 0 and self._active_sess then
                    self:_load_children(ctx, self._active_sess, ref, id, data.path)
                end
            elseif data and data.kind == "session" and data.session_id then
                manager.select_session(data.session_id)
            end
        end,
        on_selection = function(_, data) self:_select(data, true) end,
    })
end

---@private
---@param data ndap.DebugView.ItemData?
---@param focus boolean
function DebugView:_select(data, focus)
    if not data then return end
    if data.kind == "session" and data.session_id then
        manager.select_session(data.session_id)
    elseif data.kind == "stackframe" and data.frame_id then
        manager.select_frame(data.frame_id)
        if focus and data.frame_source then
            local col = data.frame_column and (data.frame_column - 1) or nil
            ui.smart_open_file(data.frame_source, data.frame_line, col, true)
        end
    elseif data.kind == "breakpoint" and data.bp_kind == "source" and data.bp_source and data.bp_line then
        ui.smart_open_file(data.bp_source, data.bp_line, nil, focus)
    end
end

-- Signal subscriptions

---@private
function DebugView:_setup_subs()
    self._subs[#self._subs + 1] = manager.on_session_added:subscribe(function(id, _, info)
        self:_reclaim_session_rows(id, info.name)
        self:_upsert_session_row(id, info)
    end)

    self._subs[#self._subs + 1] = manager.on_session_removed:subscribe(function(id)
        local item_id = _roots.sessions .. "/" .. id
        local item = self._tree:get_item(item_id)
        if item and item.data and item.data.session_info then
            item.data.session_info.state        = "terminated"
            item.data.session_info.state_reason = nil
            item.data.session_info.is_paused    = false
            self._tree:set_item_data(item_id, item.data)
        end
        if self._active_id == id then
            self:_set_active(nil, nil)
        end
    end)

    self._subs[#self._subs + 1] = manager.on_session_updated:subscribe(function(id, info)
        if info.is_paused then
            self._session_timer = _cancel_timer(self._session_timer)
            self:_upsert_session_row(id, info)
        else
            self._session_timer = _cancel_timer(self._session_timer)
            self._session_timer = _start_timer(config.antiflicker_delay, function()
                self._session_timer = nil
                self:_upsert_session_row(id, info)
            end)
        end
        if id == self._active_id and not info.is_paused then
            self._greyout_timer = _cancel_timer(self._greyout_timer)
            self._greyout_timer = _start_timer(config.antiflicker_delay, function()
                self._greyout_timer = nil
                self:_greyout_items()
            end)
        end
    end)

    self._subs[#self._subs + 1] = manager.on_session_stopped:subscribe(function(id, _)
        if id ~= self._active_id then return end
        self._greyout_timer = _cancel_timer(self._greyout_timer)
        -- GDB inferior function call: the stop is transient, undo any greyout from the
        -- preceding continued event and skip re-evaluation of stack/vars/expressions.
        if self._active_sess and self._active_sess.state_reason == "function call" then
            self:_ungreyout_items()
            return
        end
        self._query_ctx = self._query_ctx + 1
        local ctx = self._query_ctx
        self:_load_stack(ctx)
        self:_load_vars(ctx)
        self:_load_expressions(ctx)
    end)

    self._subs[#self._subs + 1] = manager.on_active_changed:subscribe(function(id, sess)
        self:_set_active(id, sess)
    end)

    self._subs[#self._subs + 1] = manager.on_selection_changed:subscribe(function(id, _)
        if id ~= self._active_id then return end
        self._query_ctx = self._query_ctx + 1
        local ctx = self._query_ctx
        self:_load_stack(ctx)
        self:_load_vars(ctx)
        self:_load_expressions(ctx)
    end)

    self._subs[#self._subs + 1] = expressions.on_change:subscribe(function()
        self:_load_expressions(self._query_ctx)
    end)

    self._subs[#self._subs + 1] = breakpoints.on_change:subscribe(function()
        self:_load_breakpoints()
    end)

    -- Adapter-verified status (verified flag, bound line, hits) is session-scoped
    -- and arrives via this event rather than the registry's on_change.
    -- Data breakpoints are session-scoped, so only the active session's matter.
    self._subs[#self._subs + 1] = manager.on_data_breakpoints_changed:subscribe(function(id)
        if id ~= self._active_id then return end
        self:_load_breakpoints()
    end)

    self._subs[#self._subs + 1] = manager.on_breakpoint_updated:subscribe(function()
        self:_load_breakpoints()
    end)
end

function DebugView:teardown()
    for _, unsub in ipairs(self._subs) do unsub() end
    self._subs = {}
    self._greyout_timer = _cancel_timer(self._greyout_timer)
    self._session_timer = _cancel_timer(self._session_timer)
end

---@private
function DebugView:_greyout_items()
    for _, item in ipairs(self._tree:get_items()) do
        local k = item.data and item.data.kind
        if k == "variable" or k == "stackframe" or k == "scope" or k == "expression" then
            item.data.greyout = true
            self._tree:set_item_data(item.id, item.data)
        end
    end
end

---@private
function DebugView:_ungreyout_items()
    for _, item in ipairs(self._tree:get_items()) do
        local k = item.data and item.data.kind
        if k == "variable" or k == "stackframe" or k == "scope" or k == "expression" then
            if item.data.greyout then
                item.data.greyout = false
                self._tree:set_item_data(item.id, item.data)
            end
        end
    end
end

-- Session rows

---A session row whose session has ended and is only kept for its history.
---@param data ndap.DebugView.ItemData?
---@return boolean
local function _is_finished(data)
    local info = data and data.session_info
    return info ~= nil and format.session_finished(info.state)
end

---Drop the rows of finished sessions matching `pred`.
---@private
---@param pred fun(data: ndap.DebugView.ItemData): boolean
function DebugView:_drop_finished_rows(pred)
    for _, item_id in ipairs(self._tree:get_children_ids(_roots.sessions)) do
        local item = self._tree:get_item(item_id)
        local data = item and item.data
        if data and _is_finished(data) and pred(data) then
            self._tree:remove_item(item_id)
        end
    end
end

---Drop the rows of terminated sessions that a newly started session's name
---reclaims: a re-run of the same target takes over its predecessor's row
---rather than stacking a second one beside it.
---@param id number  the new session, left alone
---@param name string
function DebugView:_reclaim_session_rows(id, name)
    self:_drop_finished_rows(function(data)
        return data.session_id ~= id and data.name == name
    end)
end

---Drop every finished session row, leaving live sessions untouched. Bound to
---`:Ndap clean`, alongside the run cleanup that wipes their buffers.
function DebugView:clear_finished_sessions()
    self:_drop_finished_rows(function() return true end)
end

---Drop the finished rows of just these sessions. For runs disposed of one at a
---time (`ndap.remove_run`), rather than by `:Ndap clean`: they clear what they
---started without touching rows they did not produce.
---@param ids integer[]
function DebugView:clear_sessions(ids)
    local wanted = {} ---@type table<integer, true>
    for _, id in ipairs(ids) do wanted[id] = true end
    self:_drop_finished_rows(function(data)
        return data.session_id ~= nil and wanted[data.session_id] == true
    end)
end

---@param id number
---@param info ndap.client.SessionInfo
function DebugView:_upsert_session_row(id, info)
    local item_id = _roots.sessions .. "/" .. id
    ---@type ndap.DebugView.ItemData
    local data = {
        kind         = "session",
        path         = item_id,
        name         = info.name,
        session_id   = id,
        session_info = info,
        is_current   = (self._active_id == id),
    }
    if self._tree:have_item(item_id) then
        self._tree:set_item_data(item_id, data)
    else
        self._tree:add_item(_roots.sessions, {
            id         = item_id,
            expandable = false,
            expanded   = self._expanded[item_id] ~= false,
            data       = data,
        })
    end
end

---@param id number?
---@param sess ndap.dap.Session?
function DebugView:_set_active(id, sess)
    local old_id      = self._active_id
    self._active_id   = id
    self._active_sess = sess

    -- refresh is_current flag on old and new session rows
    if old_id then
        local item = self._tree:get_item(_roots.sessions .. "/" .. old_id)
        if item and item.data then
            item.data.is_current = false
            self._tree:set_item_data(_roots.sessions .. "/" .. old_id, item.data)
        end
    end
    if id then
        local item = self._tree:get_item(_roots.sessions .. "/" .. id)
        if item and item.data then
            item.data.is_current = true
            self._tree:set_item_data(_roots.sessions .. "/" .. id, item.data)
        end
    end

    self._query_ctx = self._query_ctx + 1

    self._greyout_timer = _cancel_timer(self._greyout_timer)

    if not id then
        self:_load_breakpoints()
        self:_greyout_items()
        return
    end

    local ctx = self._query_ctx
    self._greyout_timer = _start_timer(config.antiflicker_delay, function()
        self._greyout_timer = nil
        if ctx ~= self._query_ctx then return end
        self:_greyout_items()
    end)

    self:_load_stack(ctx)
    self:_load_vars(ctx)
    self:_load_expressions(ctx)
    self:_load_breakpoints()
end

-- Data loading

---@private
---@param ctx number
function DebugView:_load_stack(ctx)
    local sess = self._active_sess
    if not sess then
        self._tree:set_children(_roots.stack, {})
        return
    end
    local thread = sess:current_thread()
    if not thread or thread.status ~= "stopped" then
        self._tree:set_children(_roots.stack, {})
        return
    end
    sess:fetch_stack_trace(thread, 50, function()
        if ctx ~= self._query_ctx then return end
        self._greyout_timer = _cancel_timer(self._greyout_timer)
        local frames = thread.stack_frames or {}
        local current_frame = sess:current_stack_frame()

        -- Crop the stack to `stack_trace_limit` frames, but never hide the current
        -- frame: if it sits deeper than the limit, extend the cutoff to include it.
        local limit = config.stack_trace_limit
        local cutoff = (limit and limit > 0) and limit or #frames
        for i, frame in ipairs(frames) do
            if current_frame and frame.id == current_frame.id then
                cutoff = math.max(cutoff, i); break
            end
        end
        -- A lone hidden frame would cost the same line as the "… more" marker, so
        -- just show it instead.
        if #frames - cutoff == 1 then cutoff = #frames end

        local items = {}
        for i = 1, math.min(cutoff, #frames) do
            local frame, path = frames[i], _roots.stack .. "/" .. i
            items[i] = {
                id = path,
                expandable = false,
                expanded = false,
                data = {
                    kind         = "stackframe",
                    path         = path,
                    name         = frame.name or "<frame>",
                    frame_id     = frame.id,
                    frame_source = frame.source and frame.source.path or nil,
                    frame_line   = frame.line,
                    frame_column = frame.column,
                    is_current   = current_frame and frame.id == current_frame.id or false,
                    greyout      = false,
                },
            }
        end
        local hidden = #frames - cutoff
        if hidden > 0 then
            items[#items + 1] = {
                id = _roots.stack .. "/__more__",
                expandable = false,
                expanded = false,
                data = {
                    kind    = "stackframe",
                    path    = _roots.stack .. "/__more__",
                    name    = ("… %d more frames"):format(hidden),
                    greyout = true,
                },
            }
        end
        self._tree:set_children(_roots.stack, items)
    end)
end

---@private
---@param ctx number
function DebugView:_load_vars(ctx)
    local sess = self._active_sess
    local root_item = self._tree:get_item(_roots.variables)
    if not sess or not root_item or not root_item.expanded then
        self._tree:set_children(_roots.variables, {})
        return
    end
    local frame = sess:current_stack_frame()
    if not frame then
        self._tree:set_children(_roots.variables, {})
        return
    end
    sess:fetch_scopes(frame, function()
        if ctx ~= self._query_ctx then return end
        self._greyout_timer = _cancel_timer(self._greyout_timer)
        local scopes = frame.scopes or {}
        local scope_items = {}
        for i, scope in ipairs(scopes) do
            local path = _roots.variables .. "/" .. (scope.name or i)
            local expanded = self._expanded[path]
            if expanded == nil then
                expanded = not (scope.expensive
                    or scope.presentationHint == "globals"
                    or scope.name == "Globals" or scope.name == "Global"
                    or scope.name == "Registers" or scope.name == "Static")
            end
            scope_items[#scope_items + 1] = {
                id         = path,
                expandable = true,
                expanded   = expanded,
                data       = {
                    kind               = "scope",
                    path               = path,
                    name               = (scope.expensive and "⏱ " or "") .. (scope.name or "scope"),
                    variablesReference = scope.variablesReference,
                    greyout            = false,
                },
            }
        end
        self._tree:merge_children(_roots.variables, scope_items)
        -- load variables for expanded scopes
        for _, si in ipairs(scope_items) do
            if si.expanded and si.data.variablesReference and si.data.variablesReference > 0 then
                self:_load_children(ctx, sess, si.data.variablesReference, si.id, si.data.path)
            end
        end
    end)
end

---@param ctx number
---@param sess ndap.dap.Session
---@param ref number
---@param parent_id any
---@param parent_path string
function DebugView:_load_children(ctx, sess, ref, parent_id, parent_path)
    local tmp = { variablesReference = ref }
    sess:fetch_variables(tmp, function()
        if ctx ~= self._query_ctx then return end
        local vars = tmp.variables or {}
        local children = {}
        for i, var in ipairs(vars) do
            local path              = parent_path .. "/" .. (var.name or i)
            local expandable        = var.variablesReference and var.variablesReference > 0
            local expanded          = expandable and (self._expanded[path] == true) or false
            local item_id           = parent_id .. "::" .. (var.name or i) .. "#" .. i
            children[#children + 1] = {
                id         = item_id,
                expandable = expandable,
                expanded   = expanded,
                data       = {
                    kind               = "variable",
                    path               = path,
                    name               = var.name or "?",
                    value              = var.value,
                    variablesReference = var.variablesReference,
                    evaluateName       = var.evaluateName,
                    greyout            = false,
                },
            }
        end
        self._tree:merge_children(parent_id, children)
        for _, child in ipairs(children) do
            if child.expanded and child.data.variablesReference and child.data.variablesReference > 0 then
                self:_load_children(ctx, sess, child.data.variablesReference, child.id, child.data.path)
            end
        end
    end)
end

---@private
---@param ctx number
function DebugView:_load_expressions(ctx)
    local root_item = self._tree:get_item(_roots.expressions)
    if not root_item or not root_item.expanded then return end

    local all = expressions.all()

    -- remove tree nodes for expressions that no longer exist
    local live = {}
    for _, e in ipairs(all) do live[_roots.expressions .. "/" .. e.internal_id] = true end
    for _, child in ipairs(self._tree:get_children(_roots.expressions)) do
        if not live[child.id] then self._tree:remove_item(child.id) end
    end

    -- ensure a tree node exists for every expression
    local existing = {}
    for _, child in ipairs(self._tree:get_children(_roots.expressions)) do
        existing[child.id] = true
    end
    for _, expr_obj in ipairs(all) do
        local item_id = _roots.expressions .. "/" .. expr_obj.internal_id
        if not existing[item_id] then
            self._tree:add_item(_roots.expressions, {
                id         = item_id,
                expandable = false,
                expanded   = false,
                data       = {
                    kind    = "expression",
                    path    = item_id,
                    name    = expr_obj.expr,
                    expr_id = expr_obj.internal_id,
                    is_na   = true,
                    value   = "not available",
                    greyout = false,
                },
            })
        else
            local item = self._tree:get_item(item_id)
            if item and item.data and item.data.name ~= expr_obj.expr then
                item.data.name = expr_obj.expr
                self._tree:set_item_data(item_id, item.data)
            end
        end
        self:_eval_expression(ctx, expr_obj)
    end
end

---@param ctx number
---@param expr_obj ndap.Expression
function DebugView:_eval_expression(ctx, expr_obj)
    local item_id = _roots.expressions .. "/" .. expr_obj.internal_id
    local sess = self._active_sess
    if not sess or not sess:current_stack_frame() then return end

    sess:evaluate({ expression = expr_obj.expr, context = "watch" }, function(body, err)
        if ctx ~= self._query_ctx then return end
        if not self._tree:have_item(item_id) then return end
        local item = self._tree:get_item(item_id)
        if not item then return end
        local data = item.data
        if err or not body then
            data.value              = "not available"
            data.is_na              = true
            data.error              = err
            data.greyout            = false
            data.variablesReference = nil
        else
            data.value              = body.result
            data.is_na              = false
            data.greyout            = false
            data.variablesReference = body.variablesReference
        end
        self._tree:set_item_data(item_id, data)
        local has_ref = data.variablesReference and data.variablesReference > 0
        self._tree:set_item_expandable(item_id, has_ref or false)
        if not has_ref then
            self._tree:remove_children(item_id)
        end
    end)
end

---@private
function DebugView:_load_breakpoints()
    local root_item = self._tree:get_item(_roots.breakpoints)
    if not root_item or not root_item.expanded then return end

    local items = {}

    local active_sess = manager.session()
    local ex_opts_unsupported = active_sess ~= nil
        and not (active_sess.capabilities and active_sess.capabilities.supportsExceptionOptions)

    -- Exception breakpoints render before all other kinds.
    for _, bp in ipairs(breakpoints.exception_breakpoints()) do
        local path = _roots.breakpoints .. "/exc/" .. bp.filter
        items[#items + 1] = {
            id         = path,
            expandable = false,
            expanded   = false,
            data       = {
                kind      = "breakpoint",
                path      = path,
                name      = bp.label,
                bp_kind   = "exception_filter",
                bp_filter = bp.filter,
                disabled  = bp.disabled,
            },
        }
    end

    for _, bp in ipairs(breakpoints.exception_name_breakpoints()) do
        local path = _roots.breakpoints .. "/excn/" .. bp.internal_id
        items[#items + 1] = {
            id         = path,
            expandable = false,
            expanded   = false,
            data       = {
                kind        = "breakpoint",
                path        = path,
                name        = bp.name,
                bp_kind     = "exception_type",
                bp_id       = bp.internal_id,
                bp_ex_name  = bp.name,
                break_mode  = bp.break_mode,
                disabled    = bp.disabled,
                unsupported = ex_opts_unsupported,
            },
        }
    end

    -- Conditional source breakpoints and function breakpoints render before plain
    -- file breakpoints, so build source rows into two buckets split on condition.
    local plain_src = {}

    for _, bp in ipairs(breakpoints.all()) do
        local short         = vim.fn.fnamemodify(bp.source, ":~:.")
        local path          = _roots.breakpoints .. "/src/" .. bp.internal_id
        local src_st        = manager.bp_status(bp.internal_id)
        local conditional   = bp.condition or bp.hit_condition or bp.log_message
        local bucket        = conditional and items or plain_src
        bucket[#bucket + 1] = {
            id         = path,
            expandable = false,
            expanded   = false,
            data       = {
                kind          = "breakpoint",
                path          = path,
                name          = short .. ":" .. bp.line .. (bp.column and (":" .. bp.column) or ""),
                bp_kind       = "source",
                bp_id         = bp.internal_id,
                bp_source     = bp.source,
                bp_line       = bp.line,
                bp_column     = bp.column,
                disabled      = bp.disabled,
                verified      = src_st and src_st.verified,
                condition     = bp.condition,
                hit_condition = bp.hit_condition,
                log_message   = bp.log_message,
            },
        }
    end

    for _, bp in ipairs(breakpoints.function_breakpoints()) do
        local path        = _roots.breakpoints .. "/fn/" .. bp.internal_id
        local fn_st       = manager.bp_status(bp.internal_id)
        items[#items + 1] = {
            id         = path,
            expandable = false,
            expanded   = false,
            data       = {
                kind     = "breakpoint",
                path     = path,
                name     = bp.name,
                bp_kind  = "function",
                bp_id    = bp.internal_id,
                disabled = bp.disabled,
                verified = fn_st and fn_st.verified,
            },
        }
    end

    if active_sess then
        for i, bp in ipairs(active_sess:data_breakpoints()) do
            local path        = _roots.breakpoints .. "/data/" .. i
            items[#items + 1] = {
                id         = path,
                expandable = false,
                expanded   = false,
                data       = {
                    kind        = "breakpoint",
                    path        = path,
                    name        = bp.name,
                    bp_kind     = "data",
                    bp_data_id  = bp.data_id,
                    access_type = bp.access_type,
                    disabled    = bp.disabled,
                    verified    = bp.verified,
                },
            }
        end
    end

    -- Plain file breakpoints render last, after data breakpoints.
    for _, item in ipairs(plain_src) do
        items[#items + 1] = item
    end

    self._tree:set_children(_roots.breakpoints, items)
end

-- Public: window management

---Create (or return existing) buffer for embedding in a window.
---@param on_deleted fun()  called when the buffer is wiped
---@return integer bufnr
function DebugView:get_bufnr(on_deleted)
    local bufnr, created = self._tree:create_buffer(on_deleted)
    if created and bufnr > 0 then
        vim.api.nvim_buf_set_name(bufnr, ui.unique_buf_name("ndap://debug-view"))
        self:_setup_keymaps(bufnr)
        -- apply initial state for any already-running sessions
        for id, sess in pairs(manager.sessions()) do
            local info = {
                id                = id,
                name              = sess.config.name or sess.config.adapter or "debug",
                state             = sess.state,
                state_reason      = sess.state_reason,
                is_paused         = sess.state == "stopped",
                nb_paused_threads = 0,
            }
            self:_upsert_session_row(id, info)
        end
        local aid = manager.active_id()
        if aid then
            self:_set_active(aid, manager.get_session(aid))
        end
    end
    return bufnr
end

---Close the DebugView window if it is currently visible. The fixedwin on_delete
---(fired on WinClosed) records the final width ratio for the next open.
function DebugView:close()
    local winid = self._tree:get_winid()
    if winid > 0 then
        vim.api.nvim_win_close(winid, true)
    end
end

---@param focus boolean
function DebugView:_open(focus)
    local winid = self._tree:get_winid()
    if winid > 0 then
        if focus then vim.api.nvim_set_current_win(winid) end
        return
    end
    local bufnr = self:get_bufnr(function() end)
    -- fixedwin owns the split's creation, width pinning, resize/ratio tracking
    -- and re-pinning across layout changes; we only layer on the view-specific
    -- window options.
    local pos = config.debug_view_position == "right" and "botright" or "topleft"
    local win = fixedwin.create_fixed_win(bufnr, {
        axis = "width",
        ratio = self._width_ratio or config.debug_view_width_ratio,
        enter = focus,
        pos = pos,
        on_delete = function(ratio) self._width_ratio = ratio end,
    })
    _win_setlocal(win, "winfixbuf", true)
    _win_setlocal(win, "signcolumn", "no")
    _win_setlocal(win, "number", false)
    _win_setlocal(win, "relativenumber", false)
    _win_setlocal(win, "wrap", false)
end

---Open the DebugView in a vertical split (or focus if already visible).
function DebugView:open()
    self:_open(true)
end

---Open the DebugView without stealing focus. No-op if already visible.
function DebugView:show()
    self:_open(false)
end

---Close the DebugView if it is visible, otherwise open and focus it.
function DebugView:toggle()
    if self._tree:get_winid() > 0 then
        self:close()
    else
        self:open()
    end
end

-- Keymaps

---Toggle a data breakpoint (watchpoint) on a variable tree node, resolving its
---dataId against the active session and prompting for an access type when the
---adapter offers several.
---@private
---@param cur ndap.util.TreeBuffer.Item  a node whose data.kind == "variable"
function DebugView:_toggle_data_breakpoint(cur)
    local sess = self._active_sess
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    if not sess:capable("supportsDataBreakpoints") then
        vim.notify("[dap] adapter does not support data breakpoints", vim.log.levels.WARN)
        return
    end
    local d          = cur.data
    local parent     = self._tree:get_parent_item(cur.id)
    local parent_ref = parent and parent.data and parent.data.variablesReference
    sess:data_breakpoint_info({ name = d.name, variablesReference = parent_ref }, function(body, err)
        if err or not body or not body.dataId then
            local why = err or (body and body.description) or "not available"
            vim.notify("[dap] cannot watch '" .. d.name .. "': " .. why, vim.log.levels.WARN)
            return
        end
        for _, bp in ipairs(sess:data_breakpoints()) do
            if bp.data_id == body.dataId then
                sess:remove_data_breakpoint(body.dataId)
                return
            end
        end
        local function add(access)
            sess:add_data_breakpoint({ data_id = body.dataId, name = d.name, access_type = access })
        end
        local types = body.accessTypes or {}
        if #types > 1 then
            select.open({ prompt = "Access type for `" .. d.name .. "`: ", items = types }, function(t)
                if t then add(t) end
            end)
        else
            add(types[1])
        end
    end)
end

---Drop the undo/redo history. Called when the state the entries refer to is
---replaced wholesale, e.g. after a project switch.
function DebugView:clear_undo()
    self._undo:clear()
end

---Builds a callback that puts a breakpoint back (`present`) or takes it away,
---capturing its state now so either direction can be replayed later.
---@private
---@param d       ndap.DebugView.ItemData  breakpoint data, read while it still exists
---@param present boolean                   the state the callback establishes
---@return fun()?  nil if this breakpoint kind can't be re-created
function DebugView:_bp_present_fn(d, present)
    if d.bp_kind == "source" and d.bp_source and d.bp_line then
        local source, line, column = assert(d.bp_source), assert(d.bp_line), d.bp_column
        local opts = {
            column        = column,
            condition     = d.condition,
            hit_condition = d.hit_condition,
            log_message   = d.log_message,
            disabled      = d.disabled,
        }
        if not present then return function() breakpoints.remove(source, line, column) end end
        return function() breakpoints.add(source, line, opts) end
    elseif d.bp_kind == "function" and d.name then
        local name, disabled = assert(d.name), d.disabled
        if not present then return function() breakpoints.remove_function(name) end end
        return function() breakpoints.add_function(name, { disabled = disabled }) end
    elseif d.bp_kind == "exception_type" and d.bp_ex_name then
        local name, mode, disabled = assert(d.bp_ex_name), d.break_mode, d.disabled
        if not present then return function() breakpoints.remove_exception_name(name) end end
        return function()
            breakpoints.add_exception_name(name, mode)
            if disabled then breakpoints.set_exception_name_enabled(name, false) end
        end
    elseif d.bp_kind == "data" and d.bp_data_id then
        local data_id = assert(d.bp_data_id)
        local args = { data_id = data_id, name = d.name, access_type = d.access_type }
        return function()
            local sess = manager.session()
            if not sess then return end
            if present then sess:add_data_breakpoint(args) else sess:remove_data_breakpoint(data_id) end
        end
    end
end

---Builds a callback that sets a breakpoint's enabled state.
---@private
---@param d       ndap.DebugView.ItemData
---@param enabled boolean
---@return fun()?
function DebugView:_bp_enabled_fn(d, enabled)
    if d.bp_kind == "source" and d.bp_source and d.bp_line then
        local source, line, column = assert(d.bp_source), assert(d.bp_line), d.bp_column
        return function() breakpoints.patch(source, line, { column = column, disabled = not enabled }) end
    elseif d.bp_kind == "function" and d.name then
        local name = assert(d.name)
        return function() breakpoints.add_function(name, { disabled = not enabled }) end
    elseif d.bp_kind == "exception_filter" and d.bp_filter then
        local filter = assert(d.bp_filter)
        return function() breakpoints.set_exception_enabled(filter, enabled) end
    elseif d.bp_kind == "exception_type" and d.bp_ex_name then
        local name = assert(d.bp_ex_name)
        return function() breakpoints.set_exception_name_enabled(name, enabled) end
    elseif d.bp_kind == "data" and d.bp_data_id then
        local data_id = d.bp_data_id
        return function()
            local sess = manager.session()
            if sess and data_id then sess:set_data_breakpoint_enabled(data_id, enabled) end
        end
    end
end

---@private
---@param bufnr integer
function DebugView:_setup_keymaps(bufnr)
    ---@param key string
    ---@param desc string
    ---@param fn fun()
    local function map(key, desc, fn)
        vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc })
    end

    -- Maps `key` in both normal and visual mode; `fn` runs once per item, on the
    -- cursor item in normal mode and on every selected line in visual mode. One
    -- keypress is one undo entry, however many items it touched.
    ---@param key  string
    ---@param desc string
    ---@param fn   fun(item: ndap.util.TreeBuffer.Item)
    local function map_items(key, desc, fn)
        map(key, desc, function()
            local cur = self._tree:get_cursor_item()
            if cur then self._undo:group(function() fn(cur) end) end
        end)
        vim.keymap.set("x", key, function()
            local first, last = vim.fn.line("v"), vim.fn.line(".")
            if first > last then first, last = last, first end
            vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
            local items = {}
            for row = first, last do
                local item = self._tree:get_item_at_row(row)
                if item then items[#items + 1] = item end
            end
            self._undo:group(function()
                for _, item in ipairs(items) do fn(item) end
            end)
        end, { buffer = bufnr, desc = desc })
    end

    map("o", "Jump to a frame or breakpoint source, keeping focus", function()
        local cur = self._tree:get_cursor_item()
        if cur then self:_select(cur.data, false) end
    end)

    map("i", "Add watch expression / function breakpoint / toggle data breakpoint", function()
        local cur = self._tree:get_cursor_item()
        if not cur then return end
        local id = tostring(cur.id)
        local function under(root) return id == root or vim.startswith(id, root .. "/") end
        if under(_roots.expressions) then
            inputwin.open({ prompt = "Watch expression: " }, function(expr)
                if not expr or expr == "" then return end
                if expressions.add(expr) then
                    self._undo:push(
                        function() _remove_expression(expr) end,
                        function() expressions.add(expr) end)
                end
            end)
        elseif under(_roots.breakpoints) then
            inputwin.open({ prompt = "Function breakpoint: " }, function(name)
                if not name or name == "" then return end
                local existed = false
                for _, bp in ipairs(breakpoints.function_breakpoints()) do
                    if bp.name == name then
                        existed = true; break
                    end
                end
                breakpoints.add_function(name)
                if not existed then
                    self._undo:push(
                        function() breakpoints.remove_function(name) end,
                        function() breakpoints.add_function(name) end)
                end
            end)
        elseif cur.data and cur.data.kind == "variable" then
            self:_toggle_data_breakpoint(cur)
        end
    end)

    map_items("d", "Remove watch expression or breakpoint", function(cur)
        if not cur.data then return end
        if cur.data.kind == "expression" then
            local expr = cur.data.name
            if _remove_expression(expr) then
                -- Undo re-adds at the end of the list; position isn't restored.
                self._undo:push(
                    function() expressions.add(expr) end,
                    function() _remove_expression(expr) end)
            end
        elseif cur.data.kind == "breakpoint" then
            local d = cur.data
            local restore, remove = self:_bp_present_fn(d, true), self:_bp_present_fn(d, false)
            local removed = false
            if d.bp_kind == "source" and d.bp_source and d.bp_line then
                removed = breakpoints.remove(d.bp_source, d.bp_line, d.bp_column)
            elseif d.bp_kind == "function" then
                removed = breakpoints.remove_function(d.name)
            elseif d.bp_kind == "exception_type" and d.bp_ex_name then
                removed = breakpoints.remove_exception_name(d.bp_ex_name)
            elseif d.bp_kind == "data" and d.bp_data_id then
                local sess = manager.session()
                if sess then
                    sess:remove_data_breakpoint(d.bp_data_id)
                    removed = true
                end
            end
            if removed and restore and remove then self._undo:push(restore, remove) end
        end
    end)

    map("r", "Rename expression", function()
        local cur = self._tree:get_cursor_item()
        if not cur or not cur.data or cur.data.kind ~= "expression" then return end
        local d = cur.data
        local id, old = d.expr_id, d.name
        if not id then return end
        inputwin.open({ prompt = "Expression: ", default = old or "" }, function(input)
            if not input or input == "" then return end
            if expressions.update(id, input) and old then
                self._undo:push(
                    function() expressions.update(id, old) end,
                    function() expressions.update(id, input) end)
            end
        end)
    end)

    map_items("x", "Toggle breakpoint enabled/disabled", function(cur)
        if not cur.data or cur.data.kind ~= "breakpoint" then return end
        local d = cur.data
        -- `d.disabled` is the state before this toggle, so it is the state the
        -- toggle establishes, and its negation the one undo goes back to.
        local was_disabled = d.disabled or false
        local restore, apply = self:_bp_enabled_fn(d, not was_disabled), self:_bp_enabled_fn(d, was_disabled)
        if restore and apply then self._undo:push(restore, apply) end
        if d.bp_kind == "source" and d.bp_source and d.bp_line then
            breakpoints.patch(d.bp_source, d.bp_line, { column = d.bp_column, disabled = not d.disabled })
        elseif d.bp_kind == "function" then
            breakpoints.add_function(d.name, { disabled = not d.disabled })
        elseif d.bp_kind == "exception_filter" and d.bp_filter then
            breakpoints.set_exception_enabled(d.bp_filter, d.disabled)
        elseif d.bp_kind == "exception_type" and d.bp_ex_name then
            breakpoints.set_exception_name_enabled(d.bp_ex_name, d.disabled)
        elseif d.bp_kind == "data" and d.bp_data_id then
            local sess = manager.session()
            if sess then sess:set_data_breakpoint_enabled(d.bp_data_id, d.disabled) end
        end
    end)

    map("c", "Change variable/expression value, breakpoint condition/hit condition, or data breakpoint access type",
        function()
            local cur = self._tree:get_cursor_item()
            if not cur or not cur.data then return end
            local d = cur.data
            if d.kind == "breakpoint" and d.bp_kind == "data" and d.bp_data_id then
                local sess = manager.session()
                if not sess then
                    vim.notify("[dap] no active session", vim.log.levels.WARN); return
                end
                local _types = { "read", "write", "readWrite" }
                local cur_at = d.access_type
                select.open({
                    prompt = "Access type for " .. d.name .. ": ",
                    items  = vim.tbl_map(function(t)
                        return { label = (t == cur_at and "● " or "  ") .. t, data = t }
                    end, _types),
                }, function(at)
                    if not at or at == cur_at then return end
                    ---@param access string?
                    local function set(access)
                        return function()
                            local s = manager.session()
                            if s then
                                s:add_data_breakpoint({ data_id = d.bp_data_id, name = d.name, access_type = access })
                            end
                        end
                    end
                    set(at)()
                    self._undo:push(set(cur_at), set(at))
                end)
            elseif d.kind == "breakpoint" and d.bp_kind == "source" and d.bp_source and d.bp_line then
                inputwin.open({ prompt = "Condition (empty to clear): ", default = d.condition or "" }, function(cond)
                    if cond == nil then return end
                    inputwin.open({ prompt = "Hit condition (empty to clear): ", default = d.hit_condition or "" },
                        function(hit)
                            if hit == nil then return end
                            local source, line, column = d.bp_source, d.bp_line, d.bp_column
                            local old_cond, old_hit = d.condition or "", d.hit_condition or ""
                            if cond == old_cond and hit == old_hit then return end
                            ---@param c string
                            ---@param h string
                            local function set(c, h)
                                return function()
                                    breakpoints.patch(source, line,
                                        { column = column, condition = c, hit_condition = h })
                                end
                            end
                            set(cond, hit)()
                            self._undo:push(set(old_cond, old_hit), set(cond, hit))
                        end)
                end)
            elseif d.kind == "breakpoint" and d.bp_kind == "exception_type" and d.bp_ex_name then
                local _modes = { "always", "unhandled", "userUnhandled", "never" }
                local cur_mode = d.break_mode
                select.open({
                    prompt = "Break mode for " .. d.bp_ex_name .. ": ",
                    items  = vim.tbl_map(function(m)
                        return { label = (m == cur_mode and "● " or "  ") .. m, data = m }
                    end, _modes),
                }, function(mode)
                    if not mode or mode == cur_mode then return end
                    local name = d.bp_ex_name
                    ---@param m string?
                    local function set(m)
                        return function() breakpoints.add_exception_name(name, m) end
                    end
                    set(mode)()
                    self._undo:push(set(cur_mode), set(mode))
                end)
            elseif d.kind == "variable" and self._active_sess then
                local parent = self._tree:get_parent_item(cur.id)
                local parent_ref = parent and parent.data and parent.data.variablesReference
                inputwin.open({ prompt = "New value: ", default = d.value or "" }, function(input)
                    if input == nil then return end
                    self._active_sess:set_variable(parent_ref,
                        {
                            name = d.name,
                            value = d.value,
                            variablesReference = d.variablesReference or 0,
                            evaluateName = d
                                .evaluateName
                        }, input,
                        function(_, err)
                            if err then return end
                            self:_load_vars(self._query_ctx)
                        end)
                end)
            elseif d.kind == "expression" and self._active_sess then
                -- A watch expression is its own l-value: pass it as evaluateName so
                -- set_variable picks setExpression/setVariable per adapter capability.
                local parent = self._tree:get_parent_item(cur.id)
                local parent_ref = parent and parent.data and parent.data.variablesReference
                -- A top-level watch has no parent variablesReference, so setVariable
                -- can't reach it; without setExpression there is no way to assign it.
                -- Bail out now rather than prompting for a value we can't apply.
                if type(parent_ref) ~= "number" and not self._active_sess:capable("supportsSetExpression") then
                    vim.notify("[dap] adapter can't set a watch expression's value (no setExpression support)",
                        vim.log.levels.WARN)
                    return
                end
                inputwin.open({ prompt = "New value: ", default = d.value or "" }, function(input)
                    if input == nil then return end
                    self._active_sess:set_variable(parent_ref,
                        {
                            name               = d.name,
                            value              = d.value,
                            variablesReference = d.variablesReference or 0,
                            evaluateName       = d.name,
                        }, input,
                        function(_, err)
                            if err then return end
                            self:_load_expressions(self._query_ctx)
                        end)
                end)
            end
        end)

    map("u", "Undo last breakpoint/expression change", function()
        self._undo:undo()
    end)

    map("<C-r>", "Redo last undone breakpoint/expression change", function()
        self._undo:redo()
    end)

    map("K", "Show details / full value", function()
        local cur = self._tree:get_cursor_item()
        if cur then node_details.show(cur.data, self._active_sess) end
    end)

    map("g?", "Show keymaps", function()
        hover.show(table.concat({
            "<CR>  Select session / switch frame / jump to breakpoint source, focusing it",
            "o     Jump to a frame or breakpoint source, keeping focus",
            "K     Show full value / session info / frame details / breakpoint details",
            "i     Add: watch expression (expressions) / function breakpoint (breakpoints) / data breakpoint (variable)",
            "d     Remove watch expression or breakpoint (visual: all selected)",
            "r     Rename expression",
            "x     Toggle breakpoint enabled/disabled (visual: all selected)",
            "c     Change variable/expression value / breakpoint condition or hit condition / exception break mode / data access type",
            "u     Undo the last breakpoint/expression change",
            "<C-r> Redo the last undone change",
        }, "\n"), { title = "Keymaps" })
    end)
end

return DebugView
