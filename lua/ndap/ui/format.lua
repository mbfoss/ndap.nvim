---@brief Shared UI presentation: how debug state becomes glyphs, highlights and
---display strings. Every view resolves its icons here, so a `config.symbols` glyph
---or an `Ndap*` highlight override lands everywhere at once. Defining those
---groups is this module's only side effect; nothing else touches buffers,
---windows or state.

local config   = require("ndap.config").current
local str_util = require("ndap.util.strutil")

local M        = {}

---One piece of a rendered row: its text and an optional highlight group.
---@alias ndap.ui.Chunk { [1]: string, [2]: string? }

---A key of `ndap.Symbols` naming one appearance.
---@alias ndap.ui.SymbolName string

-- Highlight groups

---The highlight groups ndap owns, and the stock group each links to. `default`
---links, so a colorscheme or a user `:hi` wins and re-colours that state
---everywhere it is drawn.
---@type table<string, string>
local _HL_LINKS = {
    NdapBreakpoint     = "Debug",
    NdapBreakpointSoft = "DiagnosticWarn",
    NdapDebugFrame     = "Todo",
    NdapDebugFrameLine = "DiffChange",
    NdapException      = "DiagnosticVirtualTextError",
    NdapSessionRunning = "DiagnosticOk",
    NdapSessionPaused  = "DiagnosticWarn",
    NdapSessionStopped = "NonText",
}

for name, link in pairs(_HL_LINKS) do
    vim.api.nvim_set_hl(0, name, { link = link, default = true })
end

---Ndap's highlight groups by role, so views name a role rather than a string.
M.hl = {
    breakpoint       = "NdapBreakpoint",
    breakpoint_soft  = "NdapBreakpointSoft",
    debug_frame      = "NdapDebugFrame",
    debug_frame_line = "NdapDebugFrameLine",
    exception        = "NdapException",
    session_running  = "NdapSessionRunning",
    session_paused   = "NdapSessionPaused",
    session_stopped  = "NdapSessionStopped",
}

---Highlight per symbol name. Every breakpoint flavour (conditional, pending,
---disabled, logpoint, exception, data) shares one highlight: its glyph already
---tells them apart. A name missing here falls back to `NdapBreakpoint`.
---@type table<ndap.ui.SymbolName, string>
local _HIGHLIGHTS = {
    debug_frame     = M.hl.debug_frame,
    session_running = M.hl.session_running,
    session_paused  = M.hl.session_paused,
    session_stopped = M.hl.session_stopped,
}

---@param name ndap.ui.SymbolName
---@param soft boolean?  use the muted breakpoint highlight (panels, not the gutter)
---@return string glyph
---@return string highlight
local function _symbol(name, soft)
    local fallback = soft and M.hl.breakpoint_soft or M.hl.breakpoint
    return config.symbols[name] or "●", _HIGHLIGHTS[name] or fallback
end

-- Breakpoints

---What a breakpoint looks like, independent of how it is stored. `verified` is
---the adapter-reported status: nil when no session has reported on it yet.
---@class ndap.ui.format.BreakpointSpec
---@field kind          ("source"|"function"|"exception_filter"|"exception_type"|"data")?  defaults to "source"
---@field disabled      boolean?
---@field verified      boolean?
---@field condition     string?
---@field hit_condition string?
---@field log_message   string?
---@field unsupported   boolean?  exception type the adapter does not support

---@param spec ndap.ui.format.BreakpointSpec
---@return ndap.ui.SymbolName
function M.breakpoint_symbol_name(spec)
    local kind     = spec.kind or "source"
    local pending  = spec.verified == false
    local has_cond = spec.condition or spec.hit_condition

    if spec.disabled then
        if spec.log_message then return "disabled_logpoint" end
        if has_cond then return "disabled_cond_breakpoint" end
        return "disabled_breakpoint"
    end
    if kind == "exception_type" and spec.unsupported then
        return "unsupported_breakpoint"
    end
    if kind == "exception_filter" or kind == "exception_type" then
        return "exception_breakpoint"
    end
    if kind == "data" then
        return pending and "inactive_data_breakpoint" or "data_breakpoint"
    end
    if spec.log_message then
        return pending and "inactive_logpoint" or "logpoint"
    end
    if has_cond then
        return pending and "inactive_cond_breakpoint" or "cond_breakpoint"
    end
    return pending and "inactive_breakpoint" or "active_breakpoint"
end

---@param spec ndap.ui.format.BreakpointSpec
---@param soft boolean?  muted highlight, for panel rows where the gutter red is too loud
---@return string glyph
---@return string highlight
---@return ndap.ui.SymbolName name
function M.breakpoint_symbol(spec, soft)
    local name = M.breakpoint_symbol_name(spec)
    local glyph, hl = _symbol(name, soft)
    return glyph, hl, name
end

-- Sessions

---Anything carrying a session's lifecycle: an `ndap.dap.Session`, a
---`ndap.client.SessionInfo`, or a stored row's remembered state.
---@alias ndap.ui.format.SessionSpec { state: string?, is_paused: boolean? }

---@param state string?  a `ndap.dap.Session.state` value
---@return boolean
function M.session_finished(state)
    return state == "terminated" or state == "exited"
end

---The user-facing name of a session state: DAP's vocabulary reads oddly in a UI
---("stopped" means paused at a breakpoint, "terminated" means the run is over).
---@param state string?  a `ndap.dap.Session.state` value
---@return string
function M.session_state(state)
    if state == "stopped" then return "paused" end
    if M.session_finished(state) then return "ended" end
    return state or "unknown"
end

---The user-facing name of a thread's status. Same reasoning as
---`session_state`, but a thread that ended really did exit.
---@param status string?  an `ndap.dap.Thread.status` value
---@return string
function M.thread_status(status)
    if status == "stopped" then return "paused" end
    return status or "unknown"
end

---@param spec ndap.ui.format.SessionSpec?
---@return ndap.ui.SymbolName
function M.session_symbol_name(spec)
    local state = spec and spec.state
    if M.session_finished(state) then return "session_stopped" end
    if (spec and spec.is_paused) or state == "stopped" then return "session_paused" end
    return "session_running"
end

---@param spec ndap.ui.format.SessionSpec?
---@return string glyph
---@return string highlight
---@return ndap.ui.SymbolName name
function M.session_symbol(spec)
    local name = M.session_symbol_name(spec)
    local glyph, hl = _symbol(name)
    return glyph, hl, name
end

-- Values and paths

---A value on one line: newlines become `⏎`, nothing is cropped.
---@param value any
---@return string
function M.oneline(value)
    return (tostring(value or ""):gsub("\n", "⏎"))
end

---A value on one line, cropped to `max_len`
---@param value any
---@param max_len integer
---@return string
function M.value(value, max_len)
    return (str_util.crop_for_ui(M.oneline(value), max_len))
end

---Split a path into a directory prefix and its last segment, cropping only the
---prefix (from the left) so the whole fits `budget` columns. The tail is kept
---intact even when it alone overflows.
---@param path string
---@param budget integer  columns available for the whole path
---@return string dir
---@return string tail
function M.fit_path(path, budget)
    local dir, tail = path:match("^(.*/)(.-)$")
    if not dir then return "", path end
    local room = budget - vim.fn.strdisplaywidth(tail)
    if #dir > room then dir = str_util.crop_for_ui(dir, room, true) end
    return dir, tail
end

return M
