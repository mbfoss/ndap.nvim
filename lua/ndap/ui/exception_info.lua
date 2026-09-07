---@brief The exception hover: the exception that stopped the session (id,
---description, type and adapter stack trace) in a float. View-independent, so
---`:Ndap exception_info` and the automatic hover on an exception stop share it.

local DetailBlock = require("ndap.ui.DetailBlock")
local manager     = require("ndap.manager")
local str_util    = require("ndap.util.strutil")

local M           = {}

local _FOCUS_ID   = "ndap_exception"
---Budget for the one-line summary; it annotates a source line, so it has to
---stay short.
local _MAX_LEN    = 50

---@param body ndap.dap.proto.ExceptionInfoResponseBody
local function _render(body)
    local block = DetailBlock.new({ focus_id = _FOCUS_ID })
    block:line(body.exceptionId or "Exception")
    if body.description and body.description ~= "" then
        block:blank():text(body.description)
    end
    local d = body.details
    if d then
        if d.typeName and d.typeName ~= "" then
            block:blank():kv("Type", d.typeName)
        end
        if d.message and d.message ~= "" and d.message ~= body.description then
            block:text(d.message)
        end
        if d.stackTrace and d.stackTrace ~= "" then
            block:blank():line("Stack trace:"):text(d.stackTrace)
        end
    end
    block:show("Exception")
end

---Merge a possibly multi-line message into one line, collapsing every run of
---whitespace (the line breaks included) into a single space.
---@param text string?
---@return string?
local function _flatten(text)
    if not text then return nil end
    local out = vim.trim((text:gsub("%s+", " ")))
    return out ~= "" and out or nil
end

---One line naming the exception: its type or id, plus its description merged
---onto the same line. Empty when the body says nothing.
---@param body ndap.dap.proto.ExceptionInfoResponseBody
---@return string?
local function _oneline(body)
    local d = body.details or {}
    local name = (d.typeName ~= "" and d.typeName) or body.exceptionId
    local text = _flatten((d.message ~= "" and d.message) or body.description)
    if name and text and text ~= name then return name .. ": " .. text end
    local out = text or name
    return (out and out ~= "") and out or nil
end

---Resolve a one-line summary of what `sess` stopped on: the adapter's
---exceptionInfo when it offers one, else the text the stopped event carried.
---Merged onto one line and cropped to `_MAX_LEN`. `cb` gets nil when neither
---says anything.
---@param sess ndap.dap.Session
---@param cb   fun(text: string?)
function M.oneline(sess, cb)
    local fallback = _flatten(sess.exception_description)
    ---@param text string?
    local function done(text)
        cb(text and (str_util.crop_for_ui(text, _MAX_LEN)) or nil)
    end
    if not sess:capable("supportsExceptionInfoRequest") then
        done(fallback); return
    end
    manager.exception_info(function(body)
        done((body and _oneline(body)) or fallback)
    end)
end

---Show the active session's exception info. `silent` suppresses the "no active
---session"/"not supported"/"nothing to show" notifications, for callers that
---offer the hover rather than being asked for it.
---@param opts? { silent?: boolean }
function M.show(opts)
    local silent = opts and opts.silent
    ---@param msg string
    local function warn(msg)
        if not silent then vim.notify("[dap] " .. msg, vim.log.levels.WARN) end
    end

    local sess = manager.session()
    if not sess then
        warn("no active session"); return
    end
    if not sess:capable("supportsExceptionInfoRequest") then
        warn("adapter does not support exception info"); return
    end
    manager.exception_info(function(body, err)
        if not body then
            warn(err or "no exception info available"); return
        end
        _render(body)
    end)
end

return M
