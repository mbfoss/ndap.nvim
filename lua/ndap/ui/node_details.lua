---@brief The DebugView's `K` hover: what one tree row expands into as text.
---A frame location, session state, breakpoint status, or (through `value_hover`)
---an evaluated value. Pure presentation of an `ndap.DebugView.ItemData`; it
---reads the session but owns no state and never touches the tree.

local DetailBlock = require("ndap.ui.DetailBlock")
local value_hover = require("ndap.ui.value_hover")
local manager     = require("ndap.manager")
local format      = require("ndap.ui.format")

local M           = {}

-- Every hover here shares one float identity, so moving down the tree replaces
-- the previous row's hover instead of stacking a second one on it.
local _FOCUS_ID   = "ndap_view"

---@return ndap.ui.DetailBlock
local function _block()
    return DetailBlock.new({ focus_id = _FOCUS_ID })
end

---`n total, n running, n paused` (plus exited, when any), over a session's threads.
---@param sess ndap.dap.Session
---@return string
local function _threads_summary(sess)
    local threads, running, paused = sess.threads or {}, 0, 0
    for _, thread in ipairs(threads) do
        if thread.status == "stopped" then
            paused = paused + 1
        elseif thread.status == "running" then
            running = running + 1
        end
    end
    local out = ("%d total, %d running, %s paused"):format(#threads, running, paused)
    local exited = #threads - running - paused
    if exited > 0 then out = out .. (", %d exited"):format(exited) end
    return out
end

---Fill `block` with the session hover: identity, live thread and frame state and
---any pending exception. A row whose session ended keeps only what its stored
---`session_info` knows.
---@param block ndap.ui.DetailBlock
---@param data  ndap.DebugView.ItemData
local function _session(block, data)
    local id   = data.session_id
    local info = data.session_info
    local sess = id and manager.get_session(id) or nil

    block:kv("Name", data.name)
    local state = format.session_state((sess and sess.state) or (info and info.state))
    if sess and sess.state_reason then state = state .. "  (" .. sess.state_reason .. ")" end
    block:kv("State", state)

    if not sess then
        block:blank():line("session is no longer running")
        return
    end

    block:blank():kv("Threads", _threads_summary(sess))

    local frame = sess:current_stack_frame()
    if frame then
        local src = frame.source
        local loc = src and (src.path and vim.fn.fnamemodify(src.path, ":~:.") or src.name)
        block:blank()
        block:kv("Frame", frame.name)
        block:kv("Location", loc and (loc .. ":" .. (frame.line or "?")))
    end

    if sess.exception_description then
        block:section("Exception"):text(sess.exception_description, "  ")
    end
end

---@param data ndap.DebugView.ItemData
---@param sess ndap.dap.Session?  the active session
local function _stackframe(data, sess)
    local frame
    if sess then
        local thread = sess:current_thread()
        for _, f in ipairs(thread and thread.stack_frames or {}) do
            if f.id == data.frame_id then
                frame = f; break
            end
        end
    end
    if not frame then return end

    local block = _block()
    block:line(frame.name or data.name)
    local src = frame.source
    if src then
        block:line(src.path and src.path ~= "" and vim.fn.fnamemodify(src.path, ":~:.") or src.name)
    end
    if frame.line then block:line("line " .. frame.line) end
    block:line(frame.instructionPointerReference)
    block:show("Stack Frame")
end

---Fill `block` with what identifies a breakpoint row, per breakpoint kind.
---@param block ndap.ui.DetailBlock
---@param data  ndap.DebugView.ItemData
local function _breakpoint_identity(block, data)
    if data.bp_kind == "source" then
        if data.bp_source and data.bp_source ~= "" then
            block:line(vim.fn.fnamemodify(data.bp_source, ":~:."))
        end
        if data.bp_line then block:line("line " .. data.bp_line) end
    elseif data.bp_kind == "function" then
        block:line("function: " .. (data.name or "?"))
    elseif data.bp_kind == "exception_filter" then
        block:line("filter: " .. (data.bp_filter or data.name or "?"))
    elseif data.bp_kind == "exception_type" then
        block:line("exception: " .. (data.bp_ex_name or data.name or "?"))
        if data.break_mode then block:line("break mode: " .. data.break_mode) end
        if data.unsupported then block:line("(not supported by adapter)") end
    elseif data.bp_kind == "data" then
        block:line("data: " .. (data.name or "?"))
        if data.access_type then block:line("access: " .. data.access_type) end
    end
end

---@param data ndap.DebugView.ItemData
---@param sess ndap.dap.Session?  the active session
local function _breakpoint(data, sess)
    local block = _block()
    _breakpoint_identity(block, data)

    if data.condition and data.condition ~= "" then block:line("condition: " .. data.condition) end
    if data.hit_condition and data.hit_condition ~= "" then block:line("hit: " .. data.hit_condition) end
    if data.log_message and data.log_message ~= "" then block:line("log: " .. data.log_message) end

    local st = data.bp_id and sess and sess:bp_status(data.bp_id)
    if st then
        if st.message and st.message ~= "" then block:blank():line(st.message) end
        if st.hits and st.hits > 0 then block:line("hit count: " .. st.hits) end
    end

    if data.disabled then
        block:line("disabled")
    elseif data.verified == false then
        block:line("not verified")
    elseif data.verified then
        block:line("verified")
    end
    block:show("Breakpoint")
end

---Show the hover for one DebugView row. A no-op for rows that have nothing to
---add beyond the line itself (roots, scopes).
---@param data ndap.DebugView.ItemData?
---@param sess ndap.dap.Session?  the active session
function M.show(data, sess)
    if not data or not data.kind then return end
    local kind = data.kind

    if kind == "stackframe" then
        _stackframe(data, sess)
    elseif kind == "session" then
        local block = _block()
        _session(block, data)
        block:show("Session")
    elseif kind == "variable" or kind == "expression" then
        if data.is_na then
            value_hover.show({ name = data.name, value = data.error or "not available" }, { focus_id = _FOCUS_ID })
            return
        end
        if not sess or not sess:current_stack_frame() then return end
        -- A variable is evaluated by its adapter-supplied expression when it has
        -- one; a watch expression is already the expression it names.
        local expr = (kind == "variable") and (data.evaluateName or data.name) or data.name
        value_hover.evaluate(expr, { focus_id = _FOCUS_ID, title = data.name })
    elseif kind == "breakpoint" then
        _breakpoint(data, sess)
    end
end

return M
