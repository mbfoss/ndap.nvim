---@brief Active session manager: the programmatic public API.
---Owns the "which session is active" concept that keymaps and UI subscribe to,
---and exposes the session-control operations built on it, taking their details
---directly as arguments. The DAP client (dap/client.lua) is session-id-explicit;
---this module wraps it with the active-session notion and is the single DAP-layer
---dependency surface for consumers (it also re-exports the breakpoint registry).
---It performs no user interaction: no prompts, pickers or notifications; all
---of it is in the commands module (commands.lua), a peer surface built on it.

local client            = require("ndap.dap.client")
local Signal            = require("ndap.util.Signal")

local M                 = {}

-- Re-exported client signals
-- Consumers import only manager; client is an implementation detail.

M.on_session_added      = client
    .on_session_added ---@type ndap.util.Signal<fun(id:number, sess:ndap.dap.Session, info:ndap.client.SessionInfo)>
M.on_session_removed    = client.on_session_removed ---@type ndap.util.Signal<fun(id:number)>
M.on_session_updated    = client
    .on_session_updated ---@type ndap.util.Signal<fun(id:number, info:ndap.client.SessionInfo)>
M.on_session_stopped    = client
    .on_session_stopped ---@type ndap.util.Signal<fun(id:number, info:ndap.client.SessionInfo)>
M.on_raw_message        = client
    .on_raw_message ---@type ndap.util.Signal<fun(id:number, direction:"in"|"out", msg:table)>
M.on_variable_changed   = client
    .on_variable_changed ---@type ndap.util.Signal<fun(id:number, sess:ndap.dap.Session)>
M.on_breakpoint_updated = client
    .on_breakpoint_updated ---@type ndap.util.Signal<fun(id:number, bp:table, status:ndap.dap.BpStatus)>
M.on_instruction_breakpoints_changed = client
    .on_instruction_breakpoints_changed ---@type ndap.util.Signal<fun(id:number, sess:ndap.dap.Session)>
M.on_data_breakpoints_changed = client
    .on_data_breakpoints_changed ---@type ndap.util.Signal<fun(id:number, sess:ndap.dap.Session)>

---@param id number
---@return ndap.dap.Session?
function M.get_session(id) return client.get_session(id) end

---@return table<number, ndap.dap.Session>
function M.sessions() return client.sessions() end

---@param config ndap.dap.Config
---@param callbacks? ndap.client.Callbacks
function M.start(config, callbacks) return client.start(config, callbacks) end

-- Breakpoint registry
-- The global, session-independent breakpoint registry, re-exported so the command
-- surface reaches it through manager rather than importing dap/breakpoints. It is
-- already a no-UI API that takes breakpoint details directly.
M.breakpoints = require("ndap.dap.breakpoints")

-- Active session

---Fires when the active (stepping) session changes: (id?, sess?)
M.on_active_changed    = Signal.new() ---@type ndap.util.Signal<fun(id:number?, sess:ndap.dap.Session?)>
---Fires when thread or frame selection changes in the active session: (id, sess)
M.on_selection_changed = Signal.new() ---@type ndap.util.Signal<fun(id:number, sess:ndap.dap.Session)>

---@type number?
local _active_id       = nil

-- Context id: identifies the pause an async caller is asking about. Bumped by
-- everything that makes an in-flight reply refer to the past: a state change
-- (stop, including a re-hit of the same line, resume, terminate), a session
-- switch, a thread/frame selection.
local _context_id      = 1

local function _bump_context()
    _context_id = _context_id + 1
end

---@param id number?
local function _set_active(id)
    if _active_id == id then return end
    _active_id = id
    _bump_context()
    M.on_active_changed:emit(id, id and client.get_session(id) or nil)
end

-- forward selection changes from the active session only
client.on_selection_changed:subscribe(function(id, sess)
    if id ~= _active_id then return end
    _bump_context()
    M.on_selection_changed:emit(id, sess)
end)

-- the active session changed state: stopped, resumed, terminated
client.on_session_updated:subscribe(function(id)
    if id == _active_id then _bump_context() end
end)

-- auto-promote: new session → active
client.on_session_added:subscribe(function(id)
    _set_active(id)
end)

-- auto-promote: a session stopped → bring it into focus
client.on_session_stopped:subscribe(function(id)
    _set_active(id)
end)

-- auto-reassign: active session removed → pick any remaining, or nil
client.on_session_removed:subscribe(function(id)
    if _active_id ~= id then return end
    local new_id
    for k in pairs(client.sessions()) do
        new_id = k; break
    end
    _set_active(new_id)
end)

---@return ndap.dap.Session?
function M.session()
    return _active_id and client.get_session(_active_id) or nil
end

---Return the active session's adapter-verified status for a breakpoint, or nil if no session.
---@param bp_id integer  internal stable id (bp.internal_id)
---@return ndap.dap.BpStatus?
function M.bp_status(bp_id)
    local sess = M.session()
    return sess and sess:bp_status(bp_id)
end

---@return number?
function M.active_id()
    return _active_id
end

---The current debug context's id. It increments on every session switch, run/stop
---transition and thread/frame selection, so an async caller can capture it before
---a request and drop a reply that arrives after the ground moved.
---@return number
function M.context_id()
    return _context_id
end

---Manually promote a session to the active slot.
---@param id number
function M.select_session(id)
    if client.get_session(id) then _set_active(id) end
end

-- Frame preference on stop

---A frame whose source we can show: a real file path, not deemphasized by the
---adapter. Disassembly and other adapter-served virtual sources (a bare
---`sourceReference`, e.g. codelldb's `@__cxa_throw`) don't count.
---@param frame ndap.dap.StackFrame
---@return boolean
local function _has_source(frame)
    local src = frame.source
    if not src or src.path == nil or src.path == "" then return false end
    if src.origin == "disassembly" then return false end
    if src.presentationHint == "deemphasize" then return false end
    return frame.presentationHint ~= "label" and frame.presentationHint ~= "subtle"
end

-- A stop clears the frame selection, so the session falls to the adapter's top
-- frame. When that frame has no source (an exception thrown inside a system
-- library), select the topmost frame that has one, so we land on user code.
client.on_session_stopped:subscribe(function(id)
    if vim.b.ndap_disasm then return end
    local sess   = client.get_session(id)
    local thread = sess and sess:current_thread()
    local frames = thread and thread.stack_frames
    if not frames or not frames[1] or _has_source(frames[1]) then return end
    for _, f in ipairs(frames) do
        if _has_source(f) then
            client.select_frame(id, f.id)
            return
        end
    end
end)

-- Stepping (delegate to client with active id)

---Granularity used for subsequent steps. Derived from the focused buffer:
---instruction while the disassembly pane is current, line everywhere else.
---@return ndap.dap.proto.SteppingGranularity
function M.granularity()
    if vim.b.ndap_disasm then return "instruction" end
    return "line"
end

---Whether the active session's adapter advertises `capability`. False when there
---is no active session. The command surface decides how to report the lack.
---@param capability string  e.g. "supportsRestartFrame"
---@return boolean
function M.capable(capability)
    local sess = M.session()
    return sess ~= nil and sess:capable(capability)
end

function M.continue() if _active_id then client.continue(_active_id) end end

function M.continue_all() client.continue_all() end

function M.next() if _active_id then client.next(_active_id, M.granularity()) end end

---@param target_id? integer  step into a specific call target (from step_in_targets)
function M.step_in(target_id)
    if _active_id then client.step_in(_active_id, M.granularity(), target_id) end
end

function M.step_out() if _active_id then client.step_out(_active_id, M.granularity()) end end

function M.step_back() if _active_id then client.step_back(_active_id, M.granularity()) end end

function M.reverse_continue() if _active_id then client.reverse_continue(_active_id) end end

function M.pause() if _active_id then client.pause(_active_id) end end

function M.restart() if _active_id then client.restart(_active_id) end end

---@param cb fun()?
function M.stop(cb) if _active_id then client.stop(_active_id, cb) end end

---Stop every session (adapters and debuggees).
---@param cb fun()?
function M.stop_all(cb) client.quit(cb) end

---@param cb fun()?
function M.disconnect(cb) if _active_id then client.disconnect(_active_id, cb) end end

---@param frame_id integer
---@param cb fun(targets: ndap.dap.proto.StepInTarget[]?, err: string?)
function M.step_in_targets(frame_id, cb)
    if not _active_id then cb(nil, "no active session"); return end
    client.step_in_targets(_active_id, frame_id, cb)
end

---@param source ndap.dap.proto.Source
---@param line   integer
---@param cb     fun(targets: ndap.dap.proto.GotoTarget[]?, err: string?)
function M.goto_targets(source, line, cb)
    if not _active_id then cb(nil, "no active session"); return end
    client.goto_targets(_active_id, source, line, cb)
end

---@param target_id integer
function M.set_next_statement(target_id)
    if _active_id then client.set_next_statement(_active_id, target_id) end
end

---@param frame_id integer
function M.restart_frame(frame_id)
    if _active_id then client.restart_frame(_active_id, frame_id) end
end

---@param cb fun(body: table?, err: string?)
function M.exception_info(cb)
    if not _active_id then cb(nil, "no active session"); return end
    client.exception_info(_active_id, cb)
end

---@param thread_ids integer[]
---@param cb? fun()
function M.terminate_threads(thread_ids, cb)
    if _active_id then client.terminate_threads(_active_id, thread_ids, cb) end
end

---@param thread_id integer
function M.select_thread(thread_id)
    if _active_id then client.select_thread(_active_id, thread_id) end
end

---@param frame_id integer
function M.select_frame(frame_id)
    if _active_id then client.select_frame(_active_id, frame_id) end
end

---@param text   string
---@param column integer
---@param cb     fun(targets: table[])
function M.complete(text, column, cb)
    if not _active_id then
        cb({}); return
    end
    client.complete(_active_id, text, column, cb)
end

---@param expr    string
---@param context string
---@param cb      fun(body: table?, err: string?)
function M.evaluate(expr, context, cb)
    if not _active_id then
        cb(nil, "no active session"); return
    end
    client.evaluate(_active_id, expr, context, cb)
end

return M
