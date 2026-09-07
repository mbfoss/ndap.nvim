---@brief DAP session.
---Owns one Connection, holds all runtime state (threads, frames, scopes,
---variables, modules, sources), and drives the full DAP protocol handshake.
---
---Emitted events (register with session:on(event, fn)):
---  "state_changed"     (session)                  : state / reason updated
---  "output"            (category, text)            : adapter output event
---  "stopped"           (session)                  : execution stopped
---  "continued"         (session)                  : execution resumed
---  "thread_updated"    (session)                  : thread list changed
---  "breakpoint_updated"(bp, status)               : bp verified/message changed; status is { verified, message, hits }
---  "terminated"        (session, reason)          : session ended; reason is set only when the adapter died unexpectedly
---  "run_in_terminal"   (bufnr, title)             : terminal buffer opened; title is the adapter's, may be nil
---  "start_debugging"   (child_config, parent_sess): adapter requests child session

local breakpoints = require("ndap.dap.breakpoints")
local str_util    = require("ndap.util.strutil")

---@class ndap.dap.Thread
---@field id           integer
---@field name         string
---@field status       "running"|"stopped"|"exited"
---@field stack_frames ndap.dap.StackFrame[]?
---@field total_frames integer?

---@class ndap.dap.StackFrame : ndap.dap.proto.StackFrame
---@field scopes ndap.dap.Scope[]?

---Scope augmented with a Lua-side variable cache populated by fetch_variables.
---@class ndap.dap.Scope : ndap.dap.proto.Scope
---@field variables? ndap.dap.Variable[]

---Variable augmented with a Lua-side child cache populated by fetch_variables.
---@class ndap.dap.Variable : ndap.dap.proto.Variable
---@field variables? ndap.dap.Variable[]

---Adapter-verified status for a single breakpoint tracked by the session.
---@class ndap.dap.BpStatus
---@field verified boolean?
---@field message  string?
---@field hits     integer
---@field line     integer?   adapter-resolved line, if it differs from the stored line (session-scoped)
---@field column   integer?   adapter-resolved column for a column breakpoint, if it differs from the stored column (session-scoped)

---A data breakpoint (watchpoint) tracked by the session.
---Session-scoped: dataIds are obtained per-session via dataBreakpointInfo and
---are not persisted to the project store.
---@class ndap.dap.DataBreakpoint
---@field data_id       string
---@field name          string                                   human label (variable/expression watched)
---@field access_type   ndap.dap.proto.DataBreakpointAccessType?
---@field condition     string?
---@field hit_condition string?
---@field disabled      boolean?                                 kept in the list but excluded from the synced set
---@field verified      boolean?
---@field message       string?

---@class ndap.dap.Session
---@field conn          ndap.dap.Connection
---@field config        ndap.dap.Config
---@field state         string
---@field state_reason  string?
---@field capabilities  ndap.dap.proto.Capabilities
---@field _initialized  boolean
---@field threads       ndap.dap.Thread[]
---@field _thread_id    integer?
---@field _stack_id     integer?
---@field _stop_seq     integer   identifies the current pause; see _on_stopped
---@field exception_description string?
---@field _modules      ndap.dap.proto.Module[]
---@field _sources      ndap.dap.proto.Source[]
---@field _progress     table<string, string>   active progressId -> title
---@field _source_buffers table<integer,integer>   sourceReference -> bufnr
---@field on            fun(self: ndap.dap.Session, event: string, handler: fun(...))
---@field start         fun(self: ndap.dap.Session)
---@field stop          fun(self: ndap.dap.Session, cb: fun()?)
---@field terminate     fun(self: ndap.dap.Session, cb: fun(err: string?)?)
---@field disconnect    fun(self: ndap.dap.Session, cb: fun()?)
---@field continue      fun(self: ndap.dap.Session, arguments: ndap.dap.proto.ContinueArguments?)
---@field next          fun(self: ndap.dap.Session, arguments: ndap.dap.proto.NextArguments?)
---@field step_in       fun(self: ndap.dap.Session, arguments: ndap.dap.proto.StepInArguments?)
---@field step_out      fun(self: ndap.dap.Session, arguments: ndap.dap.proto.StepOutArguments?)
---@field pause         fun(self: ndap.dap.Session, arguments: ndap.dap.proto.PauseArguments?)
---@field terminate_threads  fun(self: ndap.dap.Session, arguments: ndap.dap.proto.TerminateThreadsArguments, cb: fun(err: string?)?)
---@field step_back     fun(self: ndap.dap.Session, arguments: ndap.dap.proto.StepBackArguments?)
---@field reverse_continue   fun(self: ndap.dap.Session, arguments: ndap.dap.proto.ReverseContinueArguments?)
---@field step_in_targets    fun(self: ndap.dap.Session, arguments: ndap.dap.proto.StepInTargetsArguments, cb: fun(targets: ndap.dap.proto.StepInTarget[]?, err: string?))
---@field goto_targets       fun(self: ndap.dap.Session, arguments: ndap.dap.proto.GotoTargetsArguments, cb: fun(targets: ndap.dap.proto.GotoTarget[]?, err: string?))
---@field set_next_statement fun(self: ndap.dap.Session, arguments: ndap.dap.proto.GotoArguments)
---@field restart_frame      fun(self: ndap.dap.Session, arguments: ndap.dap.proto.RestartFrameArguments)
---@field exception_info     fun(self: ndap.dap.Session, arguments: ndap.dap.proto.ExceptionInfoArguments?, cb: fun(body: ndap.dap.proto.ExceptionInfoResponseBody?, err: string?))
---@field restart       fun(self: ndap.dap.Session)
---@field evaluate      fun(self: ndap.dap.Session, arguments: ndap.dap.proto.EvaluateArguments, cb: fun(body: ndap.dap.proto.EvaluateResponseBody?, err: string?))
---@field disassemble   fun(self: ndap.dap.Session, arguments: ndap.dap.proto.DisassembleArguments, cb: fun(instructions: ndap.dap.proto.DisassembledInstruction[]?, err: string?))
---@field instruction_breakpoints        fun(self: ndap.dap.Session): table<string, ndap.dap.BpStatus>
---@field toggle_instruction_breakpoint  fun(self: ndap.dap.Session, ref: string, cb: fun(err: string?)?)
---@field _instr_bps                     table<string, ndap.dap.BpStatus>
---@field data_breakpoints               fun(self: ndap.dap.Session): ndap.dap.DataBreakpoint[]
---@field data_breakpoint_info           fun(self: ndap.dap.Session, arguments: ndap.dap.proto.DataBreakpointInfoArguments, cb: fun(body: ndap.dap.proto.DataBreakpointInfoResponseBody?, err: string?))
---@field add_data_breakpoint            fun(self: ndap.dap.Session, entry: { data_id: string, name: string, access_type?: ndap.dap.proto.DataBreakpointAccessType, condition?: string, hit_condition?: string }, cb: fun(err: string?)?)
---@field remove_data_breakpoint         fun(self: ndap.dap.Session, data_id: string, cb: fun(err: string?)?)
---@field set_data_breakpoint_enabled    fun(self: ndap.dap.Session, data_id: string, enabled: boolean, cb: fun(err: string?)?)
---@field clear_data_breakpoints         fun(self: ndap.dap.Session, cb: fun(err: string?)?)
---@field _data_bps                      ndap.dap.DataBreakpoint[]
---@field request       fun(self: ndap.dap.Session, command: string, args: table?, cb: fun(body: table?, err: string?)?)
---@field capable       fun(self: ndap.dap.Session, name: string): boolean
---@field current_thread      fun(self: ndap.dap.Session): ndap.dap.Thread?
---@field current_stack_frame fun(self: ndap.dap.Session): ndap.dap.StackFrame?
---@field stopped_threads     fun(self: ndap.dap.Session): ndap.dap.Thread[]
---@field fetch_variables     fun(self: ndap.dap.Session, object: ndap.dap.Scope|ndap.dap.Variable, cb: fun()?, format: ndap.dap.proto.ValueFormat?)
---@field fetch_stack_trace   fun(self: ndap.dap.Session, thread: ndap.dap.Thread, levels: integer, cb: fun()?)
---@field fetch_scopes        fun(self: ndap.dap.Session, frame: ndap.dap.StackFrame, cb: fun()?)
---@field fetch_modules       fun(self: ndap.dap.Session, cb: fun(modules: ndap.dap.proto.Module[]?, err: string?)?)
---@field fetch_loaded_sources fun(self: ndap.dap.Session, cb: fun(sources: ndap.dap.proto.Source[]?, err: string?)?)
---@field set_variable        fun(self: ndap.dap.Session, reference: integer?, variable: ndap.dap.Variable, value: string, cb: fun(body: table?, err: string?)?)
---@field set_expression      fun(self: ndap.dap.Session, expression: string, value: string, cb: fun(body: table?, err: string?)?)
---@field get_source_buffer   fun(self: ndap.dap.Session, arguments: ndap.dap.proto.SourceArguments, cb: fun(bufnr: integer?, err: string?))
---@field _bp_status      table<integer, ndap.dap.BpStatus>
---@field _adapter_id_map table<integer, integer>
---@field sync_breakpoints              fun(self: ndap.dap.Session, source: string|nil, cb: fun()?)
---@field sync_function_breakpoints    fun(self: ndap.dap.Session, cb: fun()?)
---@field sync_exception_breakpoints   fun(self: ndap.dap.Session, cb: fun()?)
---@field bp_status                    fun(self: ndap.dap.Session, bp_id: integer): ndap.dap.BpStatus?
---@field completions                  fun(self: ndap.dap.Session, arguments: ndap.dap.proto.CompletionsArguments, cb: fun(targets: ndap.dap.proto.CompletionItem[]))
---@field cancel                       fun(self: ndap.dap.Session, arguments: ndap.dap.proto.CancelArguments, cb: fun(err: string?)?)
---@field read_memory                  fun(self: ndap.dap.Session, arguments: ndap.dap.proto.ReadMemoryArguments, cb: fun(body: table?, err: string?))
---@field write_memory                 fun(self: ndap.dap.Session, arguments: ndap.dap.proto.WriteMemoryArguments, cb: fun(body: table?, err: string?))
---@field breakpoint_locations         fun(self: ndap.dap.Session, arguments: ndap.dap.proto.BreakpointLocationsArguments, cb: fun(locations: table[]?, err: string?))
---@field select_thread                fun(self: ndap.dap.Session, thread_id: integer)
---@field select_frame                 fun(self: ndap.dap.Session, frame_id: integer)
---@field report                  fun(self: ndap.dap.Session, msg: string)
---@field _emit                    fun(self: ndap.dap.Session, event: string, ...)
---@field _handle_event            fun(self: ndap.dap.Session, event: string, body: table)
---@field _handle_adapter_request  fun(self: ndap.dap.Session, command: string, args: table, respond: ndap.dap.RespondFn)
---@field _on_continued            fun(self: ndap.dap.Session, body: ndap.dap.proto.ContinuedEventBody)
---@field _on_close                fun(self: ndap.dap.Session, reason: string?)
---@field _stop_timer              uv.uv_timer_t?                 force-close fallback while a disconnect is in flight
---@field _bp_unsub                (fun())?                       unsubscribe from breakpoints.on_change
---@field _on_breakpoints_changed  fun(self: ndap.dap.Session, kind: ndap.dap.BreakpointChangeKind, path: string?)

local M           = {}

---How long to wait for the adapter's `disconnect` response before force-closing.
local _DISCONNECT_TIMEOUT_MS = 3000

local Session     = {}
Session.__index   = Session

---@param conn   ndap.dap.Connection
---@param config ndap.dap.Config
---@return ndap.dap.Session
function M.new(conn, config)
    ---@type ndap.dap.Session
    local self      = setmetatable({
        conn                  = conn,
        config                = config,
        state                 = "starting",
        state_reason          = nil,
        capabilities          = {},
        _initialized          = false,
        threads               = {},
        _thread_id            = nil,
        _stack_id             = nil,
        _stop_seq             = 0,
        exception_description = nil,
        _modules              = {},
        _sources              = {},
        _source_buffers       = {},
        _bp_status            = {},
        _adapter_id_map       = {},
        _instr_bps            = {},
        _data_bps             = {},
        _progress             = {},
        _listeners            = {},
        _stop_cb              = nil,
        _stopping             = false,
        _stop_timer           = nil,
        _bp_unsub             = nil,
        report                = function(_, msg) vim.notify(msg, vim.log.levels.WARN) end,
    }, Session)

    conn.on_event   = function(event, body) self:_handle_event(event, body) end
    conn.on_request = function(cmd, args, respond) self:_handle_adapter_request(cmd, args, respond) end
    conn.on_close   = function(reason) self:_on_close(reason) end

    -- Adapter diagnostics are debugger messages, not debuggee output: they go to
    -- the REPL console rather than the progress report.
    conn.on_stderr  = function(line) self:_emit("output", "console", line .. "\n") end

    -- Keep the adapter in sync with the global breakpoint registry. The initial
    -- sync is handled by the _on_initialized handshake instead, so changes before
    -- initialization are ignored (see _on_breakpoints_changed).
    self._bp_unsub  = breakpoints.on_change:subscribe(function(kind, path)
        self:_on_breakpoints_changed(kind, path)
    end)

    return self
end

-- Listener helpers

---@alias ndap.dap.SessionEvent
---| "state_changed"
---| "selection_changed"
---| "thread_updated"
---| "breakpoint_updated"
---| "instruction_breakpoints_changed"
---| "data_breakpoints_changed"
---| "variable_changed"
---| "stopped"
---| "continued"
---| "terminated"
---| "output"
---| "start_debugging"
---| "run_in_terminal"
---| "terminal_exit"
---| "memory_changed"
---| "modules_changed"
---| "loaded_sources_changed"
---| "progress"
---| "closed"
---
---@param event   ndap.dap.SessionEvent
---@param handler fun(...)
function Session:on(event, handler)
    self._listeners[event] = self._listeners[event] or {}
    table.insert(self._listeners[event], handler)
end

---@param event ndap.dap.SessionEvent
---@param ... any
function Session:_emit(event, ...)
    local snapshot = vim.list_slice(self._listeners[event] or {})

    for _, fn in ipairs(snapshot) do
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then
            vim.api.nvim_echo(
                { { tostring(err), "ErrorMsg" } },
                true,
                { err = true }
            )
        end
    end
end

-- State helpers

---@param state  string
---@param reason string?
function Session:_set_state(state, reason)
    self.state        = state
    self.state_reason = reason
    self:_emit("state_changed", self)
end

---@param name string  capability key e.g. "supportsRestartRequest"
---@return boolean
function Session:capable(name)
    return self.capabilities[name] == true
end

-- Thread helpers

---@param id integer?
---@return ndap.dap.Thread?
function Session:_find_thread(id)
    for _, t in ipairs(self.threads) do
        if t.id == id then return t end
    end
end

---@param id     integer?
---@param status "running"|"stopped"|"exited"
function Session:_upsert_thread(id, status)
    local t = self:_find_thread(id)
    if t then
        t.status = status
    elseif id then
        table.insert(self.threads, {
            id = id, name = "thread-" .. id, status = status,
        })
    end
end

---@param thread_id  integer?
---@param all_threads boolean?
---@param status     "running"|"stopped"|"exited"
function Session:_set_thread_status(thread_id, all_threads, status)
    if all_threads then
        for _, t in ipairs(self.threads) do t.status = status end
    else
        self:_upsert_thread(thread_id, status)
    end
end

---@param id    integer?
---@param force boolean?
function Session:_select_thread(id, force)
    if id and (force or not self._thread_id) then
        self._thread_id = id
    end
end

---@return ndap.dap.Thread[]
function Session:stopped_threads()
    local r = {}
    for _, t in ipairs(self.threads) do
        if t.status == "stopped" then r[#r + 1] = t end
    end
    return r
end

---@return ndap.dap.Thread?
function Session:current_thread()
    return self:_find_thread(self._thread_id)
end

---@return ndap.dap.StackFrame?
function Session:current_stack_frame()
    local thread = self:current_thread()
    if not thread or not thread.stack_frames then return end
    if self._stack_id then
        for _, f in ipairs(thread.stack_frames) do
            if f.id == self._stack_id then return f end
        end
    end
    return thread.stack_frames[1]
end

-- Outgoing requests

---Low-level request, forwarded to the connection. Dropped (cb called with error)
---when the session is terminating or terminated so in-flight init chains drain
---fast; "terminate"/"disconnect" are always forwarded so stop()/disconnect() work.
---@param command string
---@param args    table?
---@param cb      fun(body: table?, err: string?)?
function Session:request(command, args, cb)
    if (self.state == "terminated" or self._stopping)
        and command ~= "disconnect"
    then
        if cb then cb(nil, "session " .. (self.state == "terminated" and "terminated" or "closing")) end
        return
    end
    self.conn:request(command, args, cb)
end

---@return nil
function Session:_do_initialize()
    self:request("initialize", {
        clientID                            = "ndap",
        adapterID                           = self.config.type or self.config.adapter or "",
        pathFormat                          = "path",
        linesStartAt1                       = true,
        columnsStartAt1                     = true,
        supportsRunInTerminalRequest        = true,
        supportsArgsCanBeInterpretedByShell = true,
        supportsProgressReporting           = true,
        supportsStartDebuggingRequest       = true,
    }, function(body, err)
        if err then
            self:report("[dap] initialize failed: " .. err)
            self:_shutdown("initialize failed: " .. err)
            return
        end
        self.capabilities = body or {}
        -- Per spec: send launch/attach after initialize unless the adapter uses
        -- configurationDone as the trigger (defer_launch_attach = true).
        if not self.config.defer_launch_attach then
            self:_do_launch_or_attach()
        end
    end)
end

---@param cb fun()?  called on successful response
function Session:_do_launch_or_attach(cb)
    local req_type = self.config.request or "launch"
    self:request(req_type, self:_protocol_args(), function(_, err)
        if err then
            self:report(("[dap] %s failed: %s"):format(req_type, err))
            self:_shutdown(("%s failed: %s"):format(req_type, err))
        elseif cb then
            cb()
        end
    end)
end

---@return table
function Session:_protocol_args()
    return self.config.request_args or {}
end

-- Breakpoint sync chain
---@return ndap.dap.proto.SetExceptionBreakpointsArguments
function Session:_exception_bp_params()
    local filters = {}
    for _, bp in ipairs(breakpoints.exception_breakpoints()) do
        if not bp.disabled then filters[#filters + 1] = bp.filter end
    end
    local params = { filters = filters }
    if self.capabilities.supportsExceptionOptions then
        local opts = {}
        for _, bp in ipairs(breakpoints.exception_name_breakpoints()) do
            if not bp.disabled then
                opts[#opts + 1] = { path = { { names = { bp.name } } }, breakMode = bp.break_mode }
            end
        end
        if #opts > 0 then params.exceptionOptions = opts end
    end
    return params
end

---@param cb fun()
function Session:_configure_exceptions(cb)
    local filter_defs = self.capabilities.exceptionBreakpointFilters or {}
    breakpoints.set_exception_filters(filter_defs)
    local params = self:_exception_bp_params()
    if #params.filters == 0 and not params.exceptionOptions then return cb() end
    self:request("setExceptionBreakpoints", params, function(_, err)
        if err then
            self:report("[dap] setExceptionBreakpoints failed: " .. err)
        end
        cb()
    end)
end

---@param cb fun()
function Session:_sync_source_breakpoints(cb)
    local sources = breakpoints.all_sources()
    if #sources == 0 then return cb() end
    local done = 0
    for _, source in ipairs(sources) do
        self:_sync_one_source(source, function()
            done = done + 1
            if done == #sources then cb() end
        end)
    end
end

---@param source string
---@param cb     fun()
function Session:_sync_one_source(source, cb)
    if source == "" then return cb() end
    local source_obj = { path = source }
    local active_bps = {}
    local active_req = {}
    for _, bp in ipairs(breakpoints.for_source(source)) do
        if not bp.disabled then
            -- An adapter that cannot place a breakpoint by column (codelldb
            -- tracks them by line alone) is not sent one; it would keep only the
            -- last and leave the rest undeletable.
            if bp.column and not self:capable("supportsBreakpointLocationsRequest") then
                -- Never asked of the adapter, so nothing here can verify it.
                local prev = self._bp_status[bp.internal_id]
                ---@type ndap.dap.BpStatus
                local st   = {
                    verified = false,
                    hits     = prev and prev.hits or 0,
                    message  = "adapter does not support column breakpoints",
                }
                self._bp_status[bp.internal_id] = st
                self:_emit("breakpoint_updated", bp, st)
            else
                local entry = { line = bp.line }
                if bp.column then entry.column = bp.column end
                if bp.condition and self:capable("supportsConditionalBreakpoints") then entry.condition = bp.condition end
                if bp.hit_condition and self:capable("supportsHitConditionalBreakpoints") then entry.hitCondition = bp
                    .hit_condition end
                if bp.log_message and self:capable("supportsLogPoints") then entry.logMessage = bp.log_message end
                active_bps[#active_bps + 1] = bp
                active_req[#active_req + 1] = entry
            end
        end
    end

    self:request("setBreakpoints", {
        source      = source_obj,
        breakpoints = active_req,
        lines       = vim.tbl_map(function(e) return e.line end, active_req),
    }, function(body, err)
        if err then
            self:report("[dap] setBreakpoints failed: " .. err)
        elseif body and body.breakpoints then
            for i, upd in ipairs(body.breakpoints) do
                local bp = active_bps[i]
                if bp then
                    local prev                      = self._bp_status[bp.internal_id]
                    local st                        = {
                        verified = upd.verified,
                        message  = upd.message,
                        hits     = prev and prev.hits or 0,
                        -- Track where the adapter actually bound the breakpoint, if
                        -- it moved it off the requested line/column, so the marker
                        -- can follow. Column is kept only for a column breakpoint.
                        line     = (upd.line and upd.line ~= bp.line) and upd.line or nil,
                        column   = (bp.column and upd.column and upd.column ~= bp.column)
                            and upd.column or nil,
                    }
                    self._bp_status[bp.internal_id] = st
                    if upd.id then self._adapter_id_map[upd.id] = bp.internal_id end
                    self:_emit("breakpoint_updated", bp, st)
                end
            end
        end
        cb()
    end)
end

---@param cb fun()
function Session:_sync_function_breakpoints(cb)
    self:sync_function_breakpoints(cb)
end

---@param cb fun()
function Session:_configuration_done(cb)
    if self:capable("supportsConfigurationDoneRequest") then
        self:request("configurationDone", {}, function(_, err)
            if err then
                self:report("[dap] configurationDone failed: " .. err)
            end
            cb()
        end)
    else
        cb()
    end
end

-- Full "initialized" sequence
---@return nil
function Session:_on_initialized()
    self._initialized = true
    -- An adapter may report a stop before announcing that it is initialized
    -- (bash-debug breaks at the first line); configuring must not resume it.
    if self.state ~= "stopped" then self:_set_state("initialized") end
    self:_configure_exceptions(function()
        self:_sync_source_breakpoints(function()
            self:_sync_function_breakpoints(function()
                self:_configuration_done(function()
                    if self.config.defer_launch_attach then
                        self:_do_launch_or_attach(function()
                            if self.state == "initialized" then self:_set_state("running") end
                        end)
                    elseif self.state == "initialized" then
                        self:_set_state("running")
                    end
                end)
            end)
        end)
    end)
end

-- Thread / stack refresh
---@param cb fun()?
function Session:_update_threads(cb)
    self:request("threads", {}, function(body, err)
        if not err and body and body.threads then
            local updated = {}
            for _, nt in ipairs(body.threads) do
                local existing = self:_find_thread(nt.id)
                if existing then
                    existing.name = nt.name
                    updated[#updated + 1] = existing
                else
                    updated[#updated + 1] = { id = nt.id, name = nt.name, status = "running" }
                end
            end
            self.threads = updated
            if not self._thread_id and #self.threads > 0 then
                self._thread_id = self.threads[1].id
            end
        end
        self:_emit("thread_updated", self)
        if cb then cb() end
    end)
end

---@param thread ndap.dap.Thread?
---@param levels integer
---@param cb     fun()?
function Session:_fetch_stack_trace(thread, levels, cb)
    if not thread or thread.status ~= "stopped" then return cb and cb() end
    local current = thread.stack_frames and #thread.stack_frames or 0
    local total   = thread.total_frames
    if total and current >= total then return cb and cb() end

    local args = { threadId = thread.id }
    if self:capable("supportsDelayedStackTraceLoading") and current > 0 then
        args.startFrame = current
        args.levels     = levels - current
    end

    self:request("stackTrace", args, function(body, err)
        if not err and body and body.stackFrames then
            local frames = body.stackFrames
            if self:capable("supportsDelayedStackTraceLoading") and current > 0 then
                thread.stack_frames = vim.list_extend(thread.stack_frames or {}, frames)
            else
                thread.stack_frames = frames
            end
            if type(body.totalFrames) == "number" then
                thread.total_frames = body.totalFrames
            end
        end
        if cb then cb() end
    end)
end

---@param frame ndap.dap.StackFrame?
---@param cb    fun()?
function Session:_fetch_scopes(frame, cb)
    if not frame or frame.scopes then return cb and cb() end
    self:request("scopes", { frameId = frame.id }, function(body, err)
        if not err and body and body.scopes then
            frame.scopes = body.scopes
        end
        if cb then cb() end
    end)
end

-- Invalidate + re-fetch current thread's stack → scopes, then notify.
---@param invalidate "stack_frames"|"variables"|nil
---@param cb         fun()?
function Session:_update(invalidate, cb)
    if invalidate == "stack_frames" then
        for _, t in ipairs(self.threads) do
            t.stack_frames = nil
            t.total_frames = nil
        end
    elseif invalidate == "variables" then
        for _, t in ipairs(self.threads) do
            for _, f in ipairs(t.stack_frames or {}) do
                f.scopes = nil
            end
        end
    end
    local thread = self:current_thread()
    self:_fetch_stack_trace(thread, 1, function()
        local frame = self:current_stack_frame()
        self:_fetch_scopes(frame, function()
            self:_emit("state_changed", self)
            if cb then cb() end
        end)
    end)
end

-- Incoming events

---@param event string
---@param body  table
function Session:_handle_event(event, body)
    if event == "initialized" then
        self:_on_initialized()
    elseif event == "stopped" then
        self:_on_stopped(body)
    elseif event == "continued" then
        self:_on_continued(body)
    elseif event == "output" then
        self:_on_output(body)
    elseif event == "thread" then
        self:_on_thread(body)
    elseif event == "module" then
        self:_on_module(body)
    elseif event == "loadedSource" then
        self:_on_loaded_source(body)
    elseif event == "breakpoint" then
        self:_on_breakpoint_event(body)
    elseif event == "process" then
        self:_on_process(body)
    elseif event == "exited" then
        self:_on_exited(body)
    elseif event == "terminated" then
        self:_on_terminated()
    elseif event == "invalidated" then
        self:_on_invalidated(body)
    elseif event == "memory" then
        self:_on_memory(body)
    elseif event == "progressStart" then
        self:_on_progress(body, "start")
    elseif event == "progressUpdate" then
        self:_on_progress(body, "update")
    elseif event == "progressEnd" then
        self:_on_progress(body, "end")
    elseif event == "capabilities" then
        if body and body.capabilities then
            self.capabilities = vim.tbl_extend("force", self.capabilities, body.capabilities)
            self:_configure_exceptions(function() end)
        end
    end
end

---@param body ndap.dap.proto.StoppedEventBody
function Session:_on_stopped(body)
    local tid         = body.threadId
    local reason      = body.reason
    local all_stopped = body.allThreadsStopped

    self:_set_state("stopped", reason)
    self:_select_thread(tid, true)
    self._stack_id             = nil
    self.exception_description = nil

    if reason == "exception" then
        local parts = {}
        if body.text then parts[#parts + 1] = body.text end
        if body.description then parts[#parts + 1] = body.description end
        local msg = table.concat(parts, ":\n\t") .. "\n"
        self.exception_description = msg
        self:_emit("output", "console", msg)
    end

    if body.hitBreakpointIds then
        for _, adapter_id in ipairs(body.hitBreakpointIds) do
            local bp_id = self._adapter_id_map[adapter_id]
            if bp_id then
                local st = self._bp_status[bp_id]
                if st then st.hits = st.hits + 1 end
            end
        end
    end

    -- The emit is two round trips away (threads, then stack frames), and a resume
    -- in that window is synchronous, so it would otherwise report a pause that is
    -- already over, and re-mark a running thread as stopped on the way. Abandon
    -- the chain once this stop is no longer the one the session is in.
    self._stop_seq = self._stop_seq + 1
    local seq      = self._stop_seq
    local current  = function() return seq == self._stop_seq and self.state == "stopped" end

    self:_set_thread_status(tid, all_stopped, "stopped")
    self:_update_threads(function()
        if not current() then return end
        self:_set_thread_status(tid, all_stopped, "stopped")
        self:_update("stack_frames", function()
            if not current() then return end
            self:_emit("stopped", self)
        end)
    end)
end

---@param body ndap.dap.proto.ContinuedEventBody
function Session:_on_continued(body)
    local tid           = body.threadId
    local all_continued = body.allThreadsContinued
    if all_continued == nil then all_continued = true end
    self:_set_state("running")
    self:_select_thread(tid)
    self:_set_thread_status(tid, all_continued, "running")
    self:_emit("continued", self)
end

---@param body ndap.dap.proto.OutputEventBody
function Session:_on_output(body)
    local out = body.output
    if not out then return end
    local cat = body.category or "console"
    self:_emit("output", cat, out)
end

---@param body ndap.dap.proto.ThreadEventBody
function Session:_on_thread(body)
    local tid    = body.threadId
    local reason = body.reason
    self:_select_thread(tid)
    if reason == "started" then
        self:_set_state("running")
        self:_set_thread_status(tid, false, "running")
    elseif reason == "exited" then
        self:_set_thread_status(tid, false, "exited")
    end
    self:_update_threads(function()
        self:_emit("thread_updated", self)
    end)
end

---@param body ndap.dap.proto.ModuleEventBody
function Session:_on_module(body)
    local reason = body.reason
    local mod    = body.module
    if not mod then return end
    if reason == "new" then
        self._modules[#self._modules + 1] = mod
    elseif reason == "changed" then
        for i, m in ipairs(self._modules) do
            if m.id == mod.id then
                self._modules[i] = vim.tbl_extend("force", m, mod); break
            end
        end
    elseif reason == "removed" then
        for i, m in ipairs(self._modules) do
            if m.id == mod.id then
                table.remove(self._modules, i); break
            end
        end
    end
end

---@param body ndap.dap.proto.LoadedSourceEventBody
function Session:_on_loaded_source(body)
    local reason = body.reason
    local src    = body.source
    if not src then return end
    if reason == "new" then
        self._sources[#self._sources + 1] = src
    elseif reason == "changed" then
        for i, s in ipairs(self._sources) do
            if s.id == src.id then
                self._sources[i] = vim.tbl_extend("force", s, src); break
            end
        end
    elseif reason == "removed" then
        for i, s in ipairs(self._sources) do
            if s.id == src.id then
                table.remove(self._sources, i); break
            end
        end
    end
end

---@param body ndap.dap.proto.BreakpointEventBody
function Session:_on_breakpoint_event(body)
    local upd = body.breakpoint
    if not upd or not upd.id then return end
    local bp_id = self._adapter_id_map[upd.id]
    if not bp_id then return end
    local prev             = self._bp_status[bp_id] or { hits = 0 }
    local bp               = breakpoints.find_by_internal_id(bp_id)
    local st               = {
        verified = upd.verified,
        message  = upd.message,
        hits     = prev.hits,
        -- Follow the adapter's bound line for source breakpoints (session-scoped).
        line     = (bp and bp.source and bp.source ~= "" and upd.line and upd.line ~= bp.line)
            and upd.line or nil,
        column   = (bp and bp.column and upd.column and upd.column ~= bp.column)
            and upd.column or nil,
    }
    self._bp_status[bp_id] = st
    if bp then
        self:_emit("breakpoint_updated", bp, st)
    end
end

---@param body ndap.dap.proto.ProcessEventBody
function Session:_on_process(body)
    local method = ((body.startMethod or "start") .. "ed"):gsub("^%l", string.upper)
    self:_emit("output", "console", method .. " " .. (body.name or "") .. "\n")
end

---@param body ndap.dap.proto.ExitedEventBody
function Session:_on_exited(body)
    self:_set_state("exited")
    self:_emit("output", "console", "Exit code " .. tostring(body.exitCode) .. "\n")
end

---@return nil
function Session:_on_terminated()
    self:_set_state("terminated")
    self:_emit("terminated", self)
    self:_shutdown()
end

---The adapter signals that cached data is stale and must be re-fetched.
---Only meaningful while stopped: running state holds no cached frames/scopes.
---@param body ndap.dap.proto.InvalidatedEventBody
function Session:_on_invalidated(body)
    if self.state ~= "stopped" then return end
    local areas = (body and body.areas) or {}
    local all   = #areas == 0 or vim.tbl_contains(areas, "all")
    local function area(a) return all or vim.tbl_contains(areas, a) end
    local function refresh()
        -- "variables" alone clears scopes; anything touching stacks refetches
        -- the whole stack (which also drops scopes).
        if area("variables") and not area("stacks") then
            self:_update("variables")
        else
            self:_update("stack_frames")
        end
    end
    if all or area("threads") then
        self:_update_threads(refresh)
    else
        refresh()
    end
end

---The adapter signals that a region of memory changed. Carries no cached state
---of its own; a memory view subscribes to refetch the affected range.
---@param body ndap.dap.proto.MemoryEventBody
function Session:_on_memory(body)
    if not body or not body.memoryReference then return end
    self:_emit("memory_changed", body.memoryReference, body.offset, body.count)
end

---Adapter-driven progress (e.g. slow symbol loading). Surfaced through the
---status channel and emitted for any richer progress UI.
---@param body  ndap.dap.proto.ProgressStartEventBody|ndap.dap.proto.ProgressUpdateEventBody|ndap.dap.proto.ProgressEndEventBody
---@param phase "start"|"update"|"end"
function Session:_on_progress(body, phase)
    local id = body and body.progressId
    if not id then return end
    local title
    if phase == "start" then
        title = body.title
        self._progress[id] = title
    else
        title = self._progress[id]
        if phase == "end" then self._progress[id] = nil end
    end
    if phase ~= "start" and not title then return end
    local parts = {}
    if title and title ~= "" then parts[#parts + 1] = title end
    if body.message and body.message ~= "" then parts[#parts + 1] = body.message end
    local msg = "[progress] " .. table.concat(parts, ": ")
    if body.percentage then msg = msg .. (" (%d%%)"):format(math.floor(body.percentage)) end
    if phase == "end" and #parts <= 1 then msg = msg .. " done" end
    self:report(msg)
    self:_emit("progress", phase, body)
end

---The one place a session ends, whatever ended it: a graceful stop, the adapter's
---own "terminated" event, or the adapter dying mid-protocol. The state change
---comes first, so anything failing after it still leaves the session ended.
---@param reason string?  why the connection ended, for an unexpected loss
---@return nil
function Session:_on_close(reason)
    self:_clear_stop_timer()
    if self._bp_unsub then
        self._bp_unsub(); self._bp_unsub = nil
    end
    local cb = self._stop_cb
    self._stop_cb = nil

    -- The adapter went away on its own: neither the user nor the protocol asked
    -- for this, which makes it a crash to report rather than an expected end.
    local unexpected = not self._stopping
        and self.state ~= "terminated"
        and self.state ~= "exited"

    if self.state ~= "terminated" then
        self:_set_state("terminated", unexpected and reason or nil)
        self:_emit("terminated", self, unexpected and (reason or "connection closed") or nil)
    end
    if unexpected then
        -- Notified as well as reported, as client.lua does for a failed start:
        -- the session is about to vanish from the UI with nothing else said.
        local msg = "[dap] session ended: " .. (reason or "connection closed")
        vim.notify(msg, vim.log.levels.WARN)
        self:report(msg)
    end
    if cb then cb() end

    self:_emit("closed")
end

-- Adapter-initiated requests

---@param command string
---@param args    table
---@param respond ndap.dap.RespondFn
function Session:_handle_adapter_request(command, args, respond)
    if command == "runInTerminal" then
        self:_run_in_terminal(args, respond)
    elseif command == "startDebugging" then
        local child_config = args.configuration
        if args.request then child_config.request = args.request end
        self:_emit("start_debugging", child_config, self)
        respond({})
    else
        respond(nil, "unsupported request: " .. command)
    end
end

---The debuggee's environment as a job wants it. DAP spells "do not inherit this
---variable" as a JSON `null`, which decodes to `vim.NIL` and would otherwise be
---spawned as the literal string "vim.NIL"; dropping the key is the nearest thing
---jobstart can express.
---@param env table<string, string|nil>?
---@return table<string, string>?
local function _spawn_env(env)
    if not env then return nil end
    local out = {}
    for k, v in pairs(env) do
        if v ~= vim.NIL then out[k] = tostring(v) end
    end
    return next(out) and out or nil
end

---The debuggee's working directory as a job wants it. Adapters may send an empty
---or missing `cwd`, which a spawn rejects with ENOENT; nil means "inherit".
---@param cwd string?
---@return string?
local function _spawn_cwd(cwd)
    if not cwd or cwd == "" then return nil end
    if vim.fn.isdirectory(cwd) == 0 then return nil end
    return cwd
end

---Run the debuggee in a terminal emulator of its own: `config.external_terminal`
---(command + args, either a command line or an argv list) with the debuggee's
---command line appended, detached, so it outlives Neovim rather than dying with it.
---@param cmd  string[]  the debuggee's command line
---@param args ndap.dap.proto.RunInTerminalRequestArguments
---@return integer? pid,string? error  the emulator's process id
local function _spawn_external(cmd, args)
    local emu = str_util.cmd_to_string_array(require("ndap.config").current.external_terminal)
    if not (emu[1] and emu[1] ~= "") then
        return nil, "no terminal emulator configured (set `external_terminal` in setup)"
    end
    if vim.fn.executable(emu[1]) == 0 then
        return nil, ("terminal '%s' not found on PATH"):format(emu[1])
    end

    local ok, proc = pcall(vim.system, vim.list_extend(vim.deepcopy(emu), cmd), {
        cwd    = _spawn_cwd(args.cwd),
        env    = _spawn_env(args.env),
        detach = true,
    })
    if not ok then return nil, tostring(proc) end
    return proc.pid
end

---@param args    ndap.dap.proto.RunInTerminalRequestArguments
---@param respond ndap.dap.RespondFn
function Session:_run_in_terminal(args, respond)
    local term = require("ndap.util.term")
    local cmd  = args.args or {}
    if args.argsCanBeInterpretedByShell then
        cmd = { vim.o.shell, "-c", table.concat(cmd, " ") }
    end

    -- An "external" kind wants the user's terminal emulator. Only the emulator's
    -- pid is knowable from here, and both response fields are optional anyway.
    -- An unusable emulator fails the request; an integrated terminal is not it.
    if args.kind == "external" then
        local pid, ext_err = _spawn_external(cmd, args)
        if pid then
            respond({ shellProcessId = pid })
        else
            respond(nil, "external terminal: " .. tostring(ext_err))
        end
        return
    end

    local handle
    local ok, err = pcall(function()
        handle = term.spawn(cmd, {
            cwd     = _spawn_cwd(args.cwd),
            env     = _spawn_env(args.env),
            on_exit = function() if handle then self:_emit("terminal_exit", handle.bufnr) end end,
        })
    end)
    if not ok or not handle then
        respond(nil, "failed to spawn terminal" .. (not ok and (": " .. tostring(err)) or ""))
        return
    end
    self:_emit("run_in_terminal", handle.bufnr, args.title)
    respond({ processId = handle.pid })
end

-- Lifecycle

---Start the DAP handshake (send initialize).
---@return nil
function Session:start()
    self:_set_state("starting")
    self:_do_initialize()
end

---@param reason string?
---@return nil
function Session:_shutdown(reason)
    self.conn:close(reason)
end

---Drop the pending force-close fallback. Timers are one-shot but must still be
---closed, or an adapter dying mid-disconnect leaks the handle.
---@return nil
function Session:_clear_stop_timer()
    local timer = self._stop_timer
    self._stop_timer = nil
    if timer and not timer:is_closing() then timer:close() end
end

---Ask the adapter to disconnect, then tear the transport down. `_stopping` marks
---the close as our own doing so it is not reported as a crash; the fallback timer
---force-closes an adapter that never answers. `_on_close` delivers `cb`, once.
---@param terminate_debuggee boolean
---@param cb fun()?
function Session:_disconnect(terminate_debuggee, cb)
    self._stopping   = true
    self._stop_cb    = cb
    self:_clear_stop_timer()
    self._stop_timer = vim.defer_fn(function()
        self._stop_timer = nil
        if self.state ~= "terminated" then
            self:_shutdown("adapter did not answer disconnect")
        end
    end, _DISCONNECT_TIMEOUT_MS)
    self:request("disconnect", { restart = false, terminateDebuggee = terminate_debuggee }, function()
        self:_clear_stop_timer()
        self:_shutdown()
    end)
end

---Gracefully terminate the debug session. `cb` is always called exactly once,
---even if the adapter crashes before responding (the _on_close path).
---@param cb fun()?
function Session:stop(cb)
    if self.state == "terminated" or self._stopping then
        if cb then cb() end
        return
    end
    -- Not yet initialized: skip protocol, just kill the transport.
    if self.state == "starting" then
        self._stopping = true
        self._stop_cb  = cb
        self:_shutdown()
        return
    end
    self:_disconnect((self.config.request or "launch") ~= "attach", cb)
end

---Ask the adapter to terminate the debuggee (requires supportsTerminateRequest).
---@param cb fun(err: string?)?
function Session:terminate_debuggee(cb)
    if not self:capable("supportsTerminateRequest") then
        if cb then cb("adapter does not support terminate") end
        return
    end
    self:request("terminate", {}, function(_, err)
        if cb then cb(err) end
    end)
end

---Cancel an in-flight request by its sequence number (CancelArguments.requestId)
---and/or a progress sequence (CancelArguments.progressId).
---@param arguments ndap.dap.proto.CancelArguments
---@param cb        fun(err: string?)?
function Session:cancel(arguments, cb)
    if not self:capable("supportsCancelRequest") then
        if cb then cb("adapter does not support cancel") end
        return
    end
    self:request("cancel", arguments, function(_, err)
        if cb then cb(err) end
    end)
end

---Disconnect without terminating the debuggee.
---@param cb fun()?
function Session:disconnect(cb)
    if self.state == "terminated" or self._stopping then
        if cb then cb() end
        return
    end
    self:_disconnect(false, cb)
end

-- Control flow

---Shared body for the stepping requests (next/stepIn/stepOut/stepBack). Fills in
---`threadId` (current thread) and `granularity` ("line") defaults, and strips
---`granularity` when the adapter does not advertise the capability.
---@param self      ndap.dap.Session
---@param command   string
---@param arguments ndap.dap.proto.NextArguments|ndap.dap.proto.StepInArguments|ndap.dap.proto.StepOutArguments|ndap.dap.proto.StepBackArguments|nil
local function _step_like(self, command, arguments)
    local args = vim.deepcopy(arguments or {})
    args.threadId = args.threadId or self._thread_id
    if self:capable("supportsSteppingGranularity") then
        args.granularity = args.granularity or "line"
    else
        args.granularity = nil
    end
    self:request(command, args, function(_, err)
        if err then
            self:report(("[dap] %s failed: %s"):format(command, err))
            return
        end
        self:_on_continued({ threadId = args.threadId --[[@as integer]], allThreadsContinued = false })
    end)
end

---@param arguments ndap.dap.proto.ContinueArguments?
function Session:continue(arguments)
    local args = vim.deepcopy(arguments or {})
    args.threadId = args.threadId or self._thread_id
    self:request("continue", args, function(body, err)
        if err then
            self:report("[dap] continue failed: " .. err)
            return
        end
        local all = (body and body.allThreadsContinued)
        if all == nil then all = true end
        self:_on_continued({ threadId = args.threadId, allThreadsContinued = all })
    end)
end

---@param arguments ndap.dap.proto.NextArguments?
function Session:next(arguments) _step_like(self, "next", arguments) end

---@param arguments ndap.dap.proto.StepInArguments?  set `targetId` from step_in_targets
function Session:step_in(arguments)
    _step_like(self, "stepIn", arguments)
end

---@param arguments ndap.dap.proto.StepOutArguments?
function Session:step_out(arguments) _step_like(self, "stepOut", arguments) end

---@param arguments ndap.dap.proto.StepBackArguments?
function Session:step_back(arguments)
    if not self:capable("supportsStepBack") then
        self:report("[dap] adapter does not support step back")
        return
    end
    _step_like(self, "stepBack", arguments)
end

---Resume reverse execution until a breakpoint is hit (time-travel debugging).
---Gated by the same capability as step_back.
---@param arguments ndap.dap.proto.ReverseContinueArguments?
function Session:reverse_continue(arguments)
    if not self:capable("supportsStepBack") then
        self:report("[dap] adapter does not support reverse continue")
        return
    end
    local args = vim.deepcopy(arguments or {})
    args.threadId = args.threadId or self._thread_id
    self:request("reverseContinue", args, function(_, err)
        if err then
            self:report("[dap] reverse continue failed: " .. err)
            return
        end
        self:_on_continued({ threadId = args.threadId --[[@as integer]], allThreadsContinued = false })
    end)
end

---Query the possible step-in targets for a stack frame, for use with
---`step_in(..., target_id)` to pick which call on the line to step into.
---@param arguments ndap.dap.proto.StepInTargetsArguments
---@param cb fun(targets: ndap.dap.proto.StepInTarget[]?, err: string?)
function Session:step_in_targets(arguments, cb)
    if not self:capable("supportsStepInTargetsRequest") then
        return cb(nil, "adapter does not support step-in targets")
    end
    self:request("stepInTargets", arguments, function(body, err)
        cb(body and body.targets, err)
    end)
end

---Query the valid jump-to-cursor targets at a source line.
---@param arguments ndap.dap.proto.GotoTargetsArguments
---@param cb     fun(targets: ndap.dap.proto.GotoTarget[]?, err: string?)
function Session:goto_targets(arguments, cb)
    if not self:capable("supportsGotoTargetsRequest") then
        return cb(nil, "adapter does not support goto targets")
    end
    self:request("gotoTargets", arguments, function(body, err)
        cb(body and body.targets, err)
    end)
end

---Set the next statement to execute (jump-to-cursor); code between the current
---location and the target is skipped. The adapter sends a stopped event once the
---jump completes. `targetId` comes from goto_targets; `threadId` from the current thread.
---@param arguments ndap.dap.proto.GotoArguments
function Session:set_next_statement(arguments)
    local args = vim.deepcopy(arguments or {})
    args.threadId = args.threadId or self._thread_id
    self:request("goto", args, function(_, err)
        if err then
            self:report("[dap] goto failed: " .. err)
            return
        end
        self:_on_continued({ threadId = args.threadId --[[@as integer]], allThreadsContinued = false })
    end)
end

---Restart execution of a single stack frame. The adapter sends a stopped event
---(reason "restart") once the frame has been re-entered.
---@param arguments ndap.dap.proto.RestartFrameArguments
function Session:restart_frame(arguments)
    if not self:capable("supportsRestartFrame") then
        self:report("[dap] adapter does not support restart frame")
        return
    end
    self:request("restartFrame", arguments, function(_, err)
        if err then
            self:report("[dap] restart frame failed: " .. err)
            return
        end
        self:_on_continued({ threadId = self._thread_id --[[@as integer]], allThreadsContinued = false })
    end)
end

---Fetch detailed information about the exception that caused the current stop.
---Only meaningful while stopped with reason "exception".
---@param arguments ndap.dap.proto.ExceptionInfoArguments?
---@param cb fun(body: ndap.dap.proto.ExceptionInfoResponseBody?, err: string?)
function Session:exception_info(arguments, cb)
    if not self:capable("supportsExceptionInfoRequest") then
        return cb(nil, "adapter does not support exception info")
    end
    local args = vim.deepcopy(arguments or {})
    args.threadId = args.threadId or self._thread_id
    self:request("exceptionInfo", args, cb)
end

---@param arguments ndap.dap.proto.PauseArguments?
function Session:pause(arguments)
    local args = vim.deepcopy(arguments or {})
    args.threadId = args.threadId or self._thread_id or 0
    self:request("pause", args, function(_, err)
        if err then self:report("[dap] pause failed: " .. err) end
    end)
end

---Terminate one or more threads (requires supportsTerminateThreadsRequest).
---@param arguments ndap.dap.proto.TerminateThreadsArguments
---@param cb        fun(err: string?)?
function Session:terminate_threads(arguments, cb)
    if not self:capable("supportsTerminateThreadsRequest") then
        if cb then cb("adapter does not support terminate threads") end
        return
    end
    self:request("terminateThreads", arguments, function(_, err)
        if err then self:report("[dap] terminateThreads failed: " .. err) end
        if cb then cb(err) end
    end)
end

---@return nil
function Session:restart()
    if not self:capable("supportsRestartRequest") then return end
    self.threads         = {}
    self._thread_id      = nil
    self._modules        = {}
    self._sources        = {}
    self._bp_status      = {}
    self._adapter_id_map = {}
    self._instr_bps      = {}
    self._data_bps       = {}
    self:request("restart", { arguments = self:_protocol_args() }, function(_, err)
        if err then self:report("[dap] restart failed: " .. err) end
    end)
end

---Disassemble instructions around a memory reference.
---Stateless: disassembly is a query, not cached session state.
---`resolveSymbols` defaults to true when not set in `arguments`.
---@param arguments ndap.dap.proto.DisassembleArguments
---@param cb     fun(instructions: ndap.dap.proto.DisassembledInstruction[]?, err: string?)
function Session:disassemble(arguments, cb)
    if not self:capable("supportsDisassembleRequest") then
        return cb(nil, "adapter does not support disassemble")
    end
    local args = vim.deepcopy(arguments or {})
    if args.resolveSymbols == nil then args.resolveSymbols = true end
    self:request("disassemble", args, function(body, err)
        cb(body and body.instructions, err)
    end)
end

---Read bytes from an adapter memory reference.
---@param arguments ndap.dap.proto.ReadMemoryArguments
---@param cb     fun(body: table?, err: string?)
function Session:read_memory(arguments, cb)
    if not self:capable("supportsReadMemoryRequest") then
        return cb(nil, "adapter does not support readMemory")
    end
    self:request("readMemory", arguments, cb)
end

---Write bytes to an adapter memory reference.
---@param arguments ndap.dap.proto.WriteMemoryArguments
---@param cb     fun(body: table?, err: string?)
function Session:write_memory(arguments, cb)
    if not self:capable("supportsWriteMemoryRequest") then
        return cb(nil, "adapter does not support writeMemory")
    end
    self:request("writeMemory", arguments, cb)
end

---Query valid breakpoint locations within a source range.
---@param arguments ndap.dap.proto.BreakpointLocationsArguments
---@param cb       fun(locations: table[]?, err: string?)
function Session:breakpoint_locations(arguments, cb)
    if not self:capable("supportsBreakpointLocationsRequest") then
        return cb(nil, "adapter does not support breakpointLocations")
    end
    self:request("breakpointLocations", arguments, function(body, err)
        cb(body and body.breakpoints, err)
    end)
end

---Instruction breakpoints currently set on this session, keyed by reference.
---Session-scoped: instruction references are only valid within a live session,
---so these are never persisted to the project store.
---@return table<string, ndap.dap.BpStatus> address -> verified status
function Session:instruction_breakpoints()
    return self._instr_bps
end

---Push the current instruction-breakpoint set to the adapter.
---DAP requires the full list on every call.
---@private
---@param cb fun(err: string?)?
function Session:_sync_instruction_breakpoints(cb)
    if not self:capable("supportsInstructionBreakpoints") then
        if cb then cb("adapter does not support instruction breakpoints") end
        return
    end
    local refs = vim.tbl_keys(self._instr_bps) ---@type string[]
    local args = vim.tbl_map(function(ref) return { instructionReference = ref } end, refs)
    self:request("setInstructionBreakpoints", { breakpoints = args }, function(body, err)
        if err then
            if cb then cb(err) end
            return
        end
        local results = body and body.breakpoints or {}
        for i, ref in ipairs(refs) do
            local bp = results[i]
            self._instr_bps[ref] = {
                verified = bp and bp.verified or false,
                message  = bp and bp.message,
                hits     = 0,
            }
        end
        self:_emit("instruction_breakpoints_changed", self)
        if cb then cb(nil) end
    end)
end

---Toggle an instruction breakpoint at the given reference (address).
---@param ref string  instructionReference (an instruction address)
---@param cb  fun(err: string?)?
function Session:toggle_instruction_breakpoint(ref, cb)
    if not self:capable("supportsInstructionBreakpoints") then
        self:report("[dap] adapter does not support instruction breakpoints")
        if cb then cb("unsupported") end
        return
    end
    if self._instr_bps[ref] then
        self._instr_bps[ref] = nil
    else
        self._instr_bps[ref] = { verified = false, hits = 0 }
    end
    self:_sync_instruction_breakpoints(cb)
end

-- Data breakpoints (watchpoints)

---Data breakpoints currently set on this session, in display order.
---Session-scoped: dataIds are only valid within a live session, so these are
---never persisted to the project store.
---@return ndap.dap.DataBreakpoint[]
function Session:data_breakpoints()
    return self._data_bps
end

---Resolve the dataId and supported access types for a data breakpoint. Must be
---called while stopped: with no usable `variablesReference` it scopes to the
---current frame (filling `frameId`), so `arguments.name` is read as an expression.
---@param arguments ndap.dap.proto.DataBreakpointInfoArguments
---@param cb fun(body: ndap.dap.proto.DataBreakpointInfoResponseBody?, err: string?)
function Session:data_breakpoint_info(arguments, cb)
    if not self:capable("supportsDataBreakpoints") then
        return cb(nil, "adapter does not support data breakpoints")
    end
    local args = vim.deepcopy(arguments or {})
    if not (args.variablesReference and args.variablesReference > 0) then
        args.variablesReference = nil
        if args.frameId == nil then
            local frame = self:current_stack_frame()
            if frame then args.frameId = frame.id end
        end
    end
    self:request("dataBreakpointInfo", args, cb)
end

---Add (or update) a data breakpoint with an already-resolved dataId, then push
---the full set to the adapter. Resolve `data_id` first via data_breakpoint_info.
---@param entry { data_id: string, name: string, access_type?: ndap.dap.proto.DataBreakpointAccessType, condition?: string, hit_condition?: string }
---@param cb fun(err: string?)?
function Session:add_data_breakpoint(entry, cb)
    if not self:capable("supportsDataBreakpoints") then
        self:report("[dap] adapter does not support data breakpoints")
        if cb then cb("unsupported") end
        return
    end
    for _, bp in ipairs(self._data_bps) do
        if bp.data_id == entry.data_id then
            bp.name          = entry.name
            bp.access_type   = entry.access_type
            bp.condition     = entry.condition
            bp.hit_condition = entry.hit_condition
            return self:_sync_data_breakpoints(cb)
        end
    end
    self._data_bps[#self._data_bps + 1] = {
        data_id       = entry.data_id,
        name          = entry.name,
        access_type   = entry.access_type,
        condition     = entry.condition,
        hit_condition = entry.hit_condition,
    }
    self:_sync_data_breakpoints(cb)
end

---Remove the data breakpoint with the given dataId and re-sync.
---@param data_id string
---@param cb fun(err: string?)?
function Session:remove_data_breakpoint(data_id, cb)
    for i, bp in ipairs(self._data_bps) do
        if bp.data_id == data_id then
            table.remove(self._data_bps, i)
            return self:_sync_data_breakpoints(cb)
        end
    end
    if cb then cb() end
end

---Enable/disable the data breakpoint with the given dataId and re-sync.
---Disabled breakpoints stay in the list but are dropped from the synced set.
---@param data_id string
---@param enabled boolean
---@param cb fun(err: string?)?
function Session:set_data_breakpoint_enabled(data_id, enabled, cb)
    for _, bp in ipairs(self._data_bps) do
        if bp.data_id == data_id then
            bp.disabled = not enabled
            return self:_sync_data_breakpoints(cb)
        end
    end
    if cb then cb() end
end

---Remove all data breakpoints and re-sync.
---@param cb fun(err: string?)?
function Session:clear_data_breakpoints(cb)
    if #self._data_bps == 0 then
        if cb then cb() end
        return
    end
    self._data_bps = {}
    self:_sync_data_breakpoints(cb)
end

---Push the current data-breakpoint set to the adapter.
---DAP requires the full list on every call; breakpoints not in the list are cleared.
---@private
---@param cb fun(err: string?)?
function Session:_sync_data_breakpoints(cb)
    if not self:capable("supportsDataBreakpoints") then
        if cb then cb("adapter does not support data breakpoints") end
        return
    end
    local active, list = {}, {}
    for _, bp in ipairs(self._data_bps) do
        if not bp.disabled then
            local entry = { dataId = bp.data_id }
            if bp.access_type then entry.accessType = bp.access_type end
            if bp.condition then entry.condition = bp.condition end
            if bp.hit_condition then entry.hitCondition = bp.hit_condition end
            active[#active + 1] = bp
            list[#list + 1]     = entry
        end
    end
    self:request("setDataBreakpoints", { breakpoints = list }, function(body, err)
        if err then
            self:report("[dap] setDataBreakpoints failed: " .. err)
        elseif body and body.breakpoints then
            for i, upd in ipairs(body.breakpoints) do
                local bp = active[i]
                if bp then
                    bp.verified = upd.verified
                    bp.message  = upd.message
                end
            end
        end
        self:_emit("data_breakpoints_changed", self)
        if cb then cb(err) end
    end)
end

-- Data fetching

---Evaluate an expression. When `arguments.frameId` is omitted it defaults to the
---current frame (if any thread is stopped); a "clipboard" context falls back to
---"hover" when the adapter lacks supportsClipboardContext.
---@param arguments ndap.dap.proto.EvaluateArguments
---@param cb      fun(body: ndap.dap.proto.EvaluateResponseBody?, err: string?)
function Session:evaluate(arguments, cb)
    local args = vim.deepcopy(arguments or {})
    if args.context == "clipboard" and not self:capable("supportsClipboardContext") then
        args.context = "hover"
    end
    if args.frameId == nil then
        local frame = self:current_stack_frame()
        if frame and #self:stopped_threads() > 0 then
            args.frameId = frame.id
        end
    end
    self:request("evaluate", args, cb)
end

---Fetch variables for a scope or variable object (populates .variables).
---@param object ndap.dap.Scope|ndap.dap.Variable
---@param cb     fun()?
---@param format ndap.dap.proto.ValueFormat?  hex/etc. display hints; only sent when supportsValueFormatting
function Session:fetch_variables(object, cb, format)
    local ref = object and object.variablesReference
    if not ref or ref == 0 or object.variables then
        return cb and cb()
    end
    local args = { variablesReference = ref }
    if format and self:capable("supportsValueFormatting") then
        args.format = format
    end
    self:request("variables", args, function(body, _)
        if body and body.variables then object.variables = body.variables end
        if cb then cb() end
    end)
end

---Fetch more stack frames for a thread.
---@param thread ndap.dap.Thread
---@param levels integer
---@param cb     fun()?
function Session:fetch_stack_trace(thread, levels, cb)
    self:_fetch_stack_trace(thread, levels, cb)
end

---Fetch scopes for a frame.
---@param frame ndap.dap.StackFrame
---@param cb    fun()?
function Session:fetch_scopes(frame, cb)
    self:_fetch_scopes(frame, cb)
end

---Fetch all loaded modules from the adapter (active poll; complements push-event _on_module).
---@param cb fun(modules: ndap.dap.proto.Module[]?, err: string?)?
function Session:fetch_modules(cb)
    if not self:capable("supportsModulesRequest") then
        if cb then cb(nil, "adapter does not support modulesRequest") end
        return
    end
    self:request("modules", { startModule = 0, moduleCount = 0 }, function(body, err)
        if not err and body and body.modules then
            self._modules = body.modules
            self:_emit("modules_changed", self)
        end
        if cb then cb(body and body.modules, err) end
    end)
end

---Fetch all loaded sources from the adapter (active poll; complements push-event _on_loaded_source).
---@param cb fun(sources: ndap.dap.proto.Source[]?, err: string?)?
function Session:fetch_loaded_sources(cb)
    if not self:capable("supportsLoadedSourcesRequest") then
        if cb then cb(nil, "adapter does not support loadedSourcesRequest") end
        return
    end
    self:request("loadedSources", {}, function(body, err)
        if not err and body and body.sources then
            self._sources = body.sources
            self:_emit("loaded_sources_changed", self)
        end
        if cb then cb(body and body.sources, err) end
    end)
end

---Switch the active thread and refresh its stack trace + scopes.
---@param thread_id integer
function Session:select_thread(thread_id)
    self._thread_id = thread_id
    self._stack_id  = nil
    local t         = self:current_thread()
    if t then
        t.stack_frames = nil
        t.total_frames = nil
    end
    self:_update(nil, function()
        self:_emit("selection_changed", self)
    end)
end

---Switch the active stack frame and refresh its scopes. Frames only exist while
---the owning thread is stopped, so this is a no-op when the thread is running.
---@param frame_id integer
function Session:select_frame(frame_id)
    local thread = self:current_thread()
    if not thread or thread.status ~= "stopped" then return end
    self._stack_id = frame_id
    local frame = self:current_stack_frame()
    self:_fetch_scopes(frame, function()
        self:_emit("state_changed", self)
        self:_emit("selection_changed", self)
    end)
end

---@return nil
function Session:_invalidate_variable_cache()
    local frame = self:current_stack_frame()
    if frame and frame.scopes then
        for _, scope in ipairs(frame.scopes) do
            scope.variables = nil
        end
    end
end

---Set a variable's value. Per the DAP spec, `setExpression` is used if and only if
---the variable has an `evaluateName` (a full l-value expression, which reaches
---nested targets a container-scoped `setVariable` cannot); otherwise `setVariable`.
---@param reference integer|nil  parent variablesReference (for the setVariable path)
---@param variable  ndap.dap.Variable
---@param value     string
---@param cb        fun(body: table?, err: string?)?
function Session:set_variable(reference, variable, value, cb)
    if self:capable("supportsSetExpression") and variable.evaluateName and variable.evaluateName ~= "" then
        return self:set_expression(variable.evaluateName, value, cb)
    end
    if self:capable("supportsSetVariable") and type(reference) == "number" then
        self:request("setVariable", {
            variablesReference = reference,
            name               = variable.name,
            value              = value,
        }, function(body, err)
            if err then
                self:report("[dap] setVariable failed: " .. err)
            else
                variable.variables = nil
                if body then for k, v in pairs(body) do variable[k] = v end end
                self:_invalidate_variable_cache()
                self:_emit("variable_changed")
            end
            if cb then cb(body, err) end
        end)
    else
        self:report("[dap] unable to set variable: adapter lacks capability")
    end
end

---Assign a new value to an l-value expression (e.g. a watch expression).
---Requires the `supportsSetExpression` capability; there is no `setVariable`
---fallback since a free-standing expression has no parent `variablesReference`.
---@param expression string  the l-value expression to assign to
---@param value      string  the value expression to assign
---@param cb         fun(body: table?, err: string?)?
function Session:set_expression(expression, value, cb)
    if not self:capable("supportsSetExpression") then
        self:report("[dap] unable to set expression: adapter lacks capability")
        if cb then cb(nil, "adapter lacks supportsSetExpression") end
        return
    end
    local frame = self:current_stack_frame()
    self:request("setExpression", {
        frameId    = frame and frame.id,
        expression = expression,
        value      = value,
    }, function(body, err)
        if err then
            self:report("[dap] setExpression failed: " .. err)
        else
            self:_invalidate_variable_cache()
            self:_emit("variable_changed")
        end
        if cb then cb(body, err) end
    end)
end

---Retrieve a virtual source by reference, returning a buffer number.
---The buffer is created once and cached, keyed by `arguments.sourceReference`.
---@param arguments ndap.dap.proto.SourceArguments
---@param cb  fun(bufnr: integer?, err: string?)
function Session:get_source_buffer(arguments, cb)
    local ref = arguments.sourceReference
    local existing = self._source_buffers[ref]
    if existing and vim.api.nvim_buf_is_valid(existing) then
        return cb(existing)
    end
    self:request("source", arguments, function(body, err)
        if err or not body then return cb(nil, err) end
        local buf   = vim.api.nvim_create_buf(false, true)
        local lines = vim.split(body.content or "", "\n", { plain = true })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
        local mime_ft = { ["text/javascript"] = "javascript", ["text/x-lldb.disassembly"] = "asm" }
        local ft = mime_ft[body.mimeType or ""]
        if ft then vim.api.nvim_set_option_value("filetype", ft, { buf = buf }) end
        self._source_buffers[ref] = buf
        cb(buf)
    end)
end

---Request REPL completions from the adapter for the given text.
---@param arguments ndap.dap.proto.CompletionsArguments
---@param cb       fun(targets: ndap.dap.proto.CompletionItem[])
function Session:completions(arguments, cb)
    if not self:capable("supportsCompletionsRequest") then
        cb({})
        return
    end
    self:request("completions", arguments, function(body, err)
        cb(not err and body and body.targets or {})
    end)
end

---React to a change in the global breakpoint registry by pushing it to the
---adapter; on_change is already coalesced by the registry, so this dispatches
---directly. Ignored until initialized: the handshake does the initial push.
---@param kind ndap.dap.BreakpointChangeKind
---@param path string?   affected source file for "source" changes (nil = all)
function Session:_on_breakpoints_changed(kind, path)
    if not self._initialized then return end
    if kind == "source" then
        self:sync_breakpoints(path)
    elseif kind == "function" then
        self:sync_function_breakpoints()
    elseif kind == "exception_filter" or kind == "exception_type" then
        self:sync_exception_breakpoints()
    elseif kind == "restore" then
        self:sync_breakpoints()
        self:sync_function_breakpoints()
        self:sync_exception_breakpoints()
    end
end

---Re-sync breakpoints for a specific source (or all sources) to the adapter.
---@param source string|nil  filepath, or nil for all
---@param cb     fun()?
function Session:sync_breakpoints(source, cb)
    if source then
        self:_sync_one_source(source, cb or function() end)
    else
        self:_sync_source_breakpoints(cb or function() end)
    end
end

---Re-sync function breakpoints to the adapter.
---@param cb fun()?
function Session:sync_function_breakpoints(cb)
    if not self:capable("supportsFunctionBreakpoints") then
        if cb then cb() end
        return
    end
    local active = {}
    for _, bp in ipairs(breakpoints.function_breakpoints()) do
        if not bp.disabled then active[#active + 1] = bp end
    end
    local list = {}
    for _, bp in ipairs(active) do list[#list + 1] = { name = bp.name } end
    self:request("setFunctionBreakpoints", { breakpoints = list }, function(body, err)
        if err then
            self:report("[dap] setFunctionBreakpoints failed: " .. err)
        elseif body and body.breakpoints then
            for i, upd in ipairs(body.breakpoints) do
                local bp = active[i]
                if bp then
                    local prev                      = self._bp_status[bp.internal_id]
                    local st                        = { verified = upd.verified, message = upd.message, hits = prev and
                    prev.hits or 0 }
                    self._bp_status[bp.internal_id] = st
                    if upd.id then self._adapter_id_map[upd.id] = bp.internal_id end
                    self:_emit("breakpoint_updated", bp, st)
                end
            end
        end
        if cb then cb() end
    end)
end

---Return this session's adapter-verified status for a breakpoint.
---@param bp_id integer  internal stable id (bp.internal_id)
---@return ndap.dap.BpStatus?
function Session:bp_status(bp_id)
    return self._bp_status[bp_id]
end

---Re-sync exception breakpoints to the adapter.
---@param cb fun()?
function Session:sync_exception_breakpoints(cb)
    local params = self:_exception_bp_params()
    self:request("setExceptionBreakpoints", params, function(_, err)
        if err then
            self:report("[dap] setExceptionBreakpoints failed: " .. err)
        end
        if cb then cb() end
    end)
end

return M
