---@brief Global breakpoint registry.
---All breakpoints are stored here independent of any session. This registry only
---tracks the *desired* breakpoint set; adapter-verified status (verified flag,
---bound line, hit count) is session-scoped (see ndap.dap.BpStatus) and is
---surfaced through the session's "breakpoint_updated" event, not through here.
---
---`on_change` fires whenever the desired set changes; live sessions subscribe to
---push the change to their adapter, and UI subscribes to repaint.

local Signal = require("ndap.util.Signal")

---@class ndap.dap.SourceBreakpoint
---@field internal_id   integer   internal stable id (for signs)
---@field source        string    absolute file path
---@field line          integer
---@field column        integer?  1-based column (nil = whole line); part of identity
---@field condition     string?
---@field hit_condition string?
---@field log_message   string?
---@field disabled      boolean

---@class ndap.dap.FunctionBreakpoint
---@field internal_id integer
---@field name        string
---@field disabled    boolean

---@class ndap.dap.ExceptionBreakpoint
---@field filter   string
---@field label    string
---@field default  boolean
---@field disabled boolean

---@class ndap.dap.ExceptionFilterDef
---@field filter  string
---@field label   string
---@field default boolean?

---@alias ndap.dap.ExceptionBreakMode "never"|"always"|"unhandled"|"userUnhandled"

---@class ndap.dap.ExceptionNameBreakpoint
---@field internal_id integer
---@field name        string
---@field break_mode  ndap.dap.ExceptionBreakMode
---@field disabled    boolean

---@class ndap.dap.BreakpointData
---Serialized form as the engine produces/consumes it: `internal_id` stripped
---(regenerated on restore) and `source` paths absolute. The persistence layer
---relativizes paths on the way to disk and re-absolutizes on the way back.
---@field source             table[]                  stripped source records (no internal_id; absolute path)
---@field functions          table[]                  stripped function records (no internal_id)
---@field exception_names    table[]?                 stripped exception-name records (no internal_id)
---@field exception_filters  table<string,boolean>?   filter → disabled

---@alias ndap.dap.BreakpointChangeKind "source" | "function" | "exception_filter" | "exception_type" | "restore"

local M = {}

---Fires when the desired breakpoint set changes and adapters must re-sync.
---`path` is the affected source file for "source" changes (nil = all sources).
---`_emit_change` coalesces emits to the next tick: one notify per file/kind.
M.on_change = Signal.new() ---@type ndap.util.Signal<fun(kind: ndap.dap.BreakpointChangeKind, path: string?)>

---Pending coalesced changes for the next tick, or nil when none are queued.
---@type { sources: table<string,true>, all_sources: boolean, kinds: table<string,true> }?
local _pending_change

local function _flush_changes()
    local p = _pending_change
    _pending_change = nil
    if not p then return end
    if p.all_sources then
        M.on_change:emit("source")
    else
        for path in pairs(p.sources) do M.on_change:emit("source", path) end
    end
    for kind in pairs(p.kinds) do M.on_change:emit(kind) end
end

---Queue an on_change notification, deduplicated within and deferred to the end
---of the current event-loop cycle. A whole-file ("source", nil) change subsumes
---any per-file ones queued in the same cycle.
---@param kind ndap.dap.BreakpointChangeKind
---@param path string?   affected source file ("source" kind only; nil = all)
local function _emit_change(kind, path)
    if not _pending_change then
        _pending_change = { sources = {}, all_sources = false, kinds = {} }
        vim.schedule(_flush_changes)
    end
    if kind == "source" then
        if path then
            _pending_change.sources[path] = true
        else
            _pending_change.all_sources = true
        end
    else
        _pending_change.kinds[kind] = true
    end
end

---@type ndap.dap.SourceBreakpoint[]
local _source_bps = {}
---@type ndap.dap.FunctionBreakpoint[]
local _function_bps = {}
---@type ndap.dap.ExceptionBreakpoint[]
local _exception_bps = {}
---@type ndap.dap.ExceptionNameBreakpoint[]
local _exception_name_bps = {}
---@type table<string,boolean>  filter → disabled, populated by restore() for use by set_exception_filters()
local _saved_exception_states = {}

local _next_id = 1
local function _new_id()
    local id = _next_id
    _next_id = _next_id + 1
    return id
end

---Identity test for a source breakpoint. Column is part of identity, so a
---whole-line breakpoint (column == nil) is distinct from a column breakpoint.
---@param bp     ndap.dap.SourceBreakpoint
---@param source string
---@param line   integer
---@param column integer?
---@return boolean
local function _matches(bp, source, line, column)
    return bp.source == source and bp.line == line and bp.column == column
end

-- Source breakpoints

---@param source string
---@param line   integer
---@param opts   { column?: integer, condition?: string, hit_condition?: string, log_message?: string, disabled?: boolean }?
---@return ndap.dap.SourceBreakpoint?
function M.add(source, line, opts)
    opts = opts or {}
    for _, bp in ipairs(_source_bps) do
        if _matches(bp, source, line, opts.column) then
            bp.condition     = opts.condition
            bp.hit_condition = opts.hit_condition
            bp.log_message   = opts.log_message
            bp.disabled      = opts.disabled or false
            _emit_change("source", source)
            return bp
        end
    end
    ---@type ndap.dap.SourceBreakpoint
    local bp = {
        internal_id   = _new_id(),
        source        = source,
        line          = line,
        column        = opts.column,
        condition     = opts.condition,
        hit_condition = opts.hit_condition,
        log_message   = opts.log_message,
        disabled      = opts.disabled or false,
    }
    _source_bps[#_source_bps + 1] = bp
    _emit_change("source", source)
    return bp
end

---Update individual fields on an existing breakpoint without clearing the others.
---Creates the breakpoint if it doesn't exist yet.
---Pass `""` for a string field to clear it.
---@param source string
---@param line   integer
---@param opts   { column?: integer, condition?: string, hit_condition?: string, log_message?: string, disabled?: boolean }
---@return ndap.dap.SourceBreakpoint?
function M.patch(source, line, opts)
    local column = opts.column
    local bp
    for _, b in ipairs(_source_bps) do
        if _matches(b, source, line, column) then bp = b; break end
    end
    if not bp then
        bp = {
            internal_id = _new_id(), source = source, line = line, column = column,
            disabled = false,
        }
        _source_bps[#_source_bps + 1] = bp
    end
    if opts.condition     ~= nil then bp.condition     = opts.condition     ~= "" and opts.condition     or nil end
    if opts.hit_condition ~= nil then bp.hit_condition = opts.hit_condition ~= "" and opts.hit_condition or nil end
    if opts.log_message   ~= nil then bp.log_message   = opts.log_message   ~= "" and opts.log_message   or nil end
    if opts.disabled      ~= nil then bp.disabled      = opts.disabled                                          end
    _emit_change("source", source)
    return bp
end

---@param source string
---@param line   integer
---@param column integer?  identity column (nil = the whole-line breakpoint)
---@return boolean
function M.remove(source, line, column)
    for i, bp in ipairs(_source_bps) do
        if _matches(bp, source, line, column) then
            table.remove(_source_bps, i)
            _emit_change("source", source)
            return true
        end
    end
    return false
end

---@param source string
---@param line   integer
---@param opts   { column?: integer, condition?: string, hit_condition?: string, log_message?: string, disabled?: boolean }?
---@return ndap.dap.SourceBreakpoint?
function M.toggle(source, line, opts)
    opts = opts or {}
    for i, bp in ipairs(_source_bps) do
        if _matches(bp, source, line, opts.column) then
            table.remove(_source_bps, i)
            _emit_change("source", source)
            return nil
        end
    end
    return M.add(source, line, opts)
end

---@param source string
---@return ndap.dap.SourceBreakpoint[]
function M.for_source(source)
    local r = {}
    for _, bp in ipairs(_source_bps) do
        if bp.source == source then r[#r + 1] = bp end
    end
    return r
end

---@return string[]
function M.all_sources()
    local seen, r = {}, {}
    for _, bp in ipairs(_source_bps) do
        if not seen[bp.source] then
            seen[bp.source] = true
            r[#r + 1] = bp.source
        end
    end
    return r
end

---@return ndap.dap.SourceBreakpoint[]
function M.all()
    return vim.list_extend({}, _source_bps)
end

-- Function breakpoints

---@param name string
---@param opts { disabled?: boolean }?
---@return ndap.dap.FunctionBreakpoint?
function M.add_function(name, opts)
    opts = opts or {}
    for _, bp in ipairs(_function_bps) do
        if bp.name == name then
            bp.disabled = opts.disabled or false
            _emit_change("function")
            return bp
        end
    end
    local bp = { internal_id = _new_id(), name = name, disabled = opts.disabled or false }
    _function_bps[#_function_bps + 1] = bp
    _emit_change("function")
    return bp
end

---@param name string
---@return boolean
function M.remove_function(name)
    for i, bp in ipairs(_function_bps) do
        if bp.name == name then
            table.remove(_function_bps, i)
            _emit_change("function")
            return true
        end
    end
    return false
end

---@return ndap.dap.FunctionBreakpoint[]
function M.function_breakpoints()
    return vim.list_extend({}, _function_bps)
end

-- Exception breakpoints

---@param filter_defs ndap.dap.ExceptionFilterDef[]
function M.set_exception_filters(filter_defs)
    local old = {}
    for _, bp in ipairs(_exception_bps) do old[bp.filter] = bp end
    _exception_bps = {}
    for _, def in ipairs(filter_defs) do
        local prev = old[def.filter]
        local disabled
        if prev then
            disabled = prev.disabled
        elseif _saved_exception_states[def.filter] ~= nil then
            disabled = _saved_exception_states[def.filter]
        else
            disabled = not (def.default == true)
        end
        _exception_bps[#_exception_bps + 1] = {
            filter   = def.filter,
            label    = def.label,
            default  = def.default,
            disabled = disabled,
        }
    end
    _emit_change("exception_filter")
end

---@return ndap.dap.ExceptionBreakpoint[]
function M.exception_breakpoints()
    return vim.list_extend({}, _exception_bps)
end

---@param filter  string
---@param enabled boolean
---@return boolean
function M.set_exception_enabled(filter, enabled)
    for _, bp in ipairs(_exception_bps) do
        if bp.filter == filter then
            bp.disabled = not enabled
            _emit_change("exception_filter")
            return true
        end
    end
    return false
end

-- Exception name breakpoints

---@param name       string
---@param break_mode ndap.dap.ExceptionBreakMode?  defaults to "always"
---@return ndap.dap.ExceptionNameBreakpoint?
function M.add_exception_name(name, break_mode)
    break_mode = break_mode or "always"
    for _, bp in ipairs(_exception_name_bps) do
        if bp.name == name then
            bp.break_mode = break_mode
            bp.disabled   = false
            _emit_change("exception_type")
            return bp
        end
    end
    local bp = { internal_id = _new_id(), name = name, break_mode = break_mode, disabled = false }
    _exception_name_bps[#_exception_name_bps + 1] = bp
    _emit_change("exception_type")
    return bp
end

---@param name string
---@return boolean
function M.remove_exception_name(name)
    for i, bp in ipairs(_exception_name_bps) do
        if bp.name == name then
            table.remove(_exception_name_bps, i)
            _emit_change("exception_type")
            return true
        end
    end
    return false
end

---Toggle: removes if present, adds (with break_mode) if absent.
---@param name       string
---@param break_mode ndap.dap.ExceptionBreakMode?
---@return ndap.dap.ExceptionNameBreakpoint?
function M.toggle_exception_name(name, break_mode)
    for i, bp in ipairs(_exception_name_bps) do
        if bp.name == name then
            table.remove(_exception_name_bps, i)
            _emit_change("exception_type")
            return nil
        end
    end
    return M.add_exception_name(name, break_mode)
end

---@return ndap.dap.ExceptionNameBreakpoint[]
function M.exception_name_breakpoints()
    return vim.list_extend({}, _exception_name_bps)
end

---@param name    string
---@param enabled boolean
---@return boolean
function M.set_exception_name_enabled(name, enabled)
    for _, bp in ipairs(_exception_name_bps) do
        if bp.name == name then
            bp.disabled = not enabled
            _emit_change("exception_type")
            return true
        end
    end
    return false
end

-- Lookup

---@param id integer  internal stable id (bp.internal_id)
---@return ndap.dap.SourceBreakpoint|ndap.dap.FunctionBreakpoint|nil
function M.find_by_internal_id(id)
    for _, bp in ipairs(_source_bps)   do if bp.internal_id == id then return bp end end
    for _, bp in ipairs(_function_bps) do if bp.internal_id == id then return bp end end
end

---@class ndap.dap.BreakpointPosition
---@field lnum integer   1-based line
---@field col  integer   0-based extmark column

---Update stored positions for a set of source breakpoints in one pass, emitting
---on_change at most once. `positions` maps internal_id → {lnum, col} (0-based col
---from extmarks); col becomes 1-based and applies only to column breakpoints.
---@param positions table<integer, ndap.dap.BreakpointPosition>
function M.relocate_batch(positions)
    local changed = false
    for _, bp in ipairs(_source_bps) do
        local pos = positions[bp.internal_id]
        if pos then
            local new_col = bp.column and (pos.col + 1) or nil
            if bp.line ~= pos.lnum or bp.column ~= new_col then
                bp.line   = pos.lnum
                bp.column = new_col
                changed   = true
            end
        end
    end
    if changed then _emit_change("source") end
end

---Enable all source breakpoints.
function M.enable_all()
    local changed = false
    for _, bp in ipairs(_source_bps) do
        if bp.disabled then bp.disabled = false; changed = true end
    end
    if changed then _emit_change("source") end
end

---Disable all source breakpoints.
function M.disable_all()
    local changed = false
    for _, bp in ipairs(_source_bps) do
        if not bp.disabled then bp.disabled = true; changed = true end
    end
    if changed then _emit_change("source") end
end

-- Persistence

---Build the serialized breakpoint set: fresh records with `internal_id` stripped.
---Source paths are absolute, exactly as the engine holds them; rewriting them for
---portable storage (and back) is the persistence layer's job, not the engine's.
---@return ndap.dap.BreakpointData
function M.get_data()
    local sources = {}
    for _, bp in ipairs(_source_bps) do
        sources[#sources + 1] = {
            source        = bp.source,
            line          = bp.line,
            column        = bp.column,
            condition     = bp.condition,
            hit_condition = bp.hit_condition,
            log_message   = bp.log_message,
            disabled      = bp.disabled,
        }
    end
    local functions = {}
    for _, bp in ipairs(_function_bps) do
        functions[#functions + 1] = { name = bp.name, disabled = bp.disabled }
    end
    local exception_names = {}
    for _, bp in ipairs(_exception_name_bps) do
        exception_names[#exception_names + 1] = {
            name = bp.name, break_mode = bp.break_mode, disabled = bp.disabled,
        }
    end
    local exc_states = {}
    for _, bp in ipairs(_exception_bps) do exc_states[bp.filter] = bp.disabled end
    return {
        source            = sources,
        functions         = functions,
        exception_names   = exception_names,
        exception_filters = exc_states,
    }
end

---Source paths are expected to be absolute; the persistence layer resolves them
---before calling restore.
---@param data ndap.dap.BreakpointData?
function M.restore(data)
    _source_bps              = (type(data) == "table" and data.source)          or {}
    _function_bps            = (type(data) == "table" and data.functions)       or {}
    _exception_name_bps      = (type(data) == "table" and data.exception_names) or {}
    _saved_exception_states  = (type(data) == "table" and type(data.exception_filters) == "table"
                                    and data.exception_filters) or {}
    local max_id = 0
    for _, bp in ipairs(_source_bps)         do if bp.internal_id and bp.internal_id > max_id then max_id = bp.internal_id end end
    for _, bp in ipairs(_function_bps)       do if bp.internal_id and bp.internal_id > max_id then max_id = bp.internal_id end end
    for _, bp in ipairs(_exception_name_bps) do if bp.internal_id and bp.internal_id > max_id then max_id = bp.internal_id end end
    if max_id >= _next_id then _next_id = max_id + 1 end
    for _, bp in ipairs(_source_bps)         do if not bp.internal_id then bp.internal_id = _new_id() end end
    for _, bp in ipairs(_function_bps)       do if not bp.internal_id then bp.internal_id = _new_id() end end
    for _, bp in ipairs(_exception_name_bps) do if not bp.internal_id then bp.internal_id = _new_id() end end
    _emit_change("restore")
end

return M
