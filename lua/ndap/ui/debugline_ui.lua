---@brief Singleton that shows the current execution position as a sign + line highlight.
---Tracks the active session; clears/moves the sign on stopped/continued/terminated.

local exception_info = require("ndap.ui.exception_info")
local fileextmarks   = require("ndap.util.fileextmarks")
local manager        = require("ndap.manager")
local ui_util        = require("ndap.util.ui")
local config         = require("ndap.config").current
local format         = require("ndap.ui.format")
local timer          = require("ndap.util.timer")

local M              = {}

local _init_done

---@type ndap.util.fileextmarks.GroupFunctions?
local _sign_group
---@type ndap.util.fileextmarks.GroupFunctions?
local _line_group
local _sign_id     = 1 -- fixed id: we only ever show one debugline sign at a time
local _ex_id       = 2 -- the exception annotation, the frameline group's other mark
---@type function?  stop fn for the pending deferred clear, if any
local _stop_clear_timer

local _SIGN_HL     = format.hl.debug_frame
local _LINE_HL     = format.hl.debug_frame_line
local _EX_HL       = format.hl.exception

---Annotate the frame line with what the session stopped on, once the adapter
---has told us. Nothing is placed for a stop that is not an exception, or one no
---adapter text describes.
---
---The adapter can answer after the pause the text describes is gone, so the
---annotation belongs to the context it was requested in: anything that ends that
---pause: a resume, a re-hit of the same breakpoint, a frame or session switch,
---drops the reply.
---@param sess ndap.dap.Session
---@param path string
---@param lnum integer
local function _show_exception(sess, path, lnum)
    if sess.state_reason ~= "exception" then return end
    local context = manager.context_id()
    exception_info.oneline(sess, function(text)
        if not text or not _line_group then return end
        if manager.context_id() ~= context then return end
        _line_group.set_file_extmark({
            id    = _ex_id,
            file  = path,
            lnum  = lnum,
            col   = 0,
            opts  = {
                virt_text     = { { "  " .. config.symbols.exception_breakpoint .. " " .. text, _EX_HL } },
                virt_text_pos = "eol",
                hl_mode       = "combine",
                priority      = 100,
            },
        })
    end)
end

---@param sess ndap.dap.Session
local function _show_stopped(sess)
    if not _sign_group or not _line_group then return end
    local frame = sess:current_stack_frame()
    if not frame then return end
    local src = frame.source
    if not src or not src.path or src.path == "" then return end
    local lnum = (frame.line and frame.line > 0) and frame.line or 1
    -- Above Neovim's default sign priority (DECOR_PRIORITY_BASE = 4096), which is
    -- what an extmark sign placed without an explicit priority gets (e.g. keystone
    -- bookmarks). The current frame must win the gutter cell against those.
    _sign_group.set_file_extmark({
        id   = _sign_id,
        file = src.path,
        lnum = lnum,
        col  = 0,
        opts = { sign_text = config.symbols.debug_frame, sign_hl_group = _SIGN_HL, priority = 5000, hl_mode = "blend" },
    })
    _line_group.set_file_extmark({
        id   = _sign_id,
        file = src.path,
        lnum = lnum,
        col  = 0,
        opts = { line_hl_group = _LINE_HL, priority = 40 },
    })
    if sess.state_reason == "function call" then
        return -- spurious stop triggered by gdp
    end
    local col = frame.column and (frame.column - 1) or nil
    ui_util.smart_open_file(src.path, lnum, col, false)
    _show_exception(sess, src.path, lnum)
end

local function _remove_marks()
    if _sign_group then _sign_group.remove_extmarks() end
    if _line_group then _line_group.remove_extmarks() end
end

local function _cancel_clear_timer()
    if _stop_clear_timer then
        _stop_clear_timer()
        _stop_clear_timer = nil
    end
end

local function _clear()
    _cancel_clear_timer()
    _remove_marks()
end

---Clear after `delay_ms` to avoid flicker during step-through.
---@param delay_ms integer
local function _deferred_clear(delay_ms)
    _cancel_clear_timer()
    _stop_clear_timer = timer.defer(delay_ms, function()
        _stop_clear_timer = nil
        _remove_marks()
    end)
end

function M.init()
    if _init_done then return end
    _init_done = true

    _sign_group = fileextmarks.define_group("ndap.framesign")
    _line_group = fileextmarks.define_group("ndap.frameline")

    -- Everything below listens to the session-independent signals and filters on
    -- the active id. Subscribing to the session object instead would mean a fresh
    -- handler set per activation with no way to drop the previous one.
    manager.on_active_changed:subscribe(function(_, sess)
        _clear()
        if sess and sess.state == "stopped" then _show_stopped(sess) end
    end)

    manager.on_session_stopped:subscribe(function(id)
        local sess = manager.session()
        if id ~= manager.active_id() or not sess then return end
        _clear()
        _show_stopped(sess)
    end)

    -- The sign is gone once there is no pause left to point at. A session that
    -- ended clears now, since nothing can flicker back in, where a resume clears late,
    -- so stepping doesn't blink the sign off and on.
    --
    -- "Running" is not enough on its own to say the pause is over: a thread
    -- starting under a live breakpoint puts the whole session in that state. The
    -- thread the sign belongs to is what settles it.
    manager.on_session_updated:subscribe(function(id, info)
        if id ~= manager.active_id() then return end
        if info.state == "terminated" or info.state == "exited" then
            _clear()
            return
        end
        if info.is_paused then return end
        local sess   = manager.session()
        local thread = sess and sess:current_thread()
        if thread and thread.status == "stopped" then return end
        _deferred_clear(config.antiflicker_delay)
    end)

    manager.on_selection_changed:subscribe(function(_, sess)
        _clear()
        if sess then _show_stopped(sess) end
    end)
end

return M
