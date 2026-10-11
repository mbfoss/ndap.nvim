---@brief DAP connection layer.
---Manages a single adapter connection (stdio pipe or TCP socket).
---Handles Content-Length framing, request/response correlation, and
---dispatching events and adapter-initiated requests to the session.

local transport = require("ndap.dap.transport")

local M = {}

---@alias ndap.dap.ResponseCb fun(body: table?, err: string?)
---@alias ndap.dap.RespondFn  fun(result: table?, err: string?)

---@class ndap.dap.ConnOpts
---@field on_close? fun(reason: string?)

---@class ndap.dap.StdioOpts : ndap.dap.ConnOpts
---@field cwd? string
---@field env? table<string,string>

---@class ndap.dap.TcpOpts : ndap.dap.ConnOpts

---@class ndap.dap.Connection
---@field _seq           integer                     monotonic request counter
---@field _pending       table<integer, ndap.dap.ResponseCb>
---@field _closed        boolean
---@field _close_reason  string?                     why the connection ended
---@field _write         fun(data: string)           raises when the adapter is gone
---@field _close         fun()
---@field on_event       fun(event: string, body: table)
---@field on_request     fun(command: string, args: table, respond: ndap.dap.RespondFn)
---@field on_close       fun(reason: string?)
---@field on_stderr      fun(line: string)
---@field on_raw_message fun(direction: "in"|"out", msg: ndap.dap.Message)
---@field _next_seq      fun(self: ndap.dap.Connection): integer
---@field _dispatch      fun(self: ndap.dap.Connection, msg: ndap.dap.Message)
---@field request        fun(self: ndap.dap.Connection, command: string, args: table?, cb: ndap.dap.ResponseCb?)
---@field close          fun(self: ndap.dap.Connection, reason: string?)

local Connection = {}
Connection.__index = Connection

function Connection:_next_seq()
    self._seq = self._seq + 1
    return self._seq
end

---Dispatch a decoded message from the adapter.
---@param msg ndap.dap.Message
function Connection:_dispatch(msg)
    self.on_raw_message("in", msg)
    local t = msg.type
    if t == "response" then
        local seq = tonumber(msg.request_seq)
        local cb  = seq and self._pending[seq]
        if seq and cb then
            self._pending[seq] = nil
            local err
            if not msg.success then
                err = msg.message
                -- Some adapters embed the human-readable reason inside body.error.format
                if not err then
                    local body = msg.body
                    err = body and body.error and body.error.format or "request failed"
                end
            end
            cb(msg.body, err)
        end
    elseif t == "event" then
        pcall(self.on_event, msg.event or "", msg.body or {})
    elseif t == "request" then
        -- Adapter-initiated request (e.g. runInTerminal, startDebugging)
        local req_seq = tonumber(msg.seq)
        local command = msg.command or ""
        ---@param result  table?   response body; sent only on success
        ---@param err_msg string?  error message; non-nil marks the response failed
        local function respond(result, err_msg)
            if self._closed then return end
            ---@type ndap.dap.Message
            local response = {
                type        = "response",
                seq         = self:_next_seq(),
                request_seq = req_seq,
                command     = command,
                success     = (err_msg == nil),
            }
            if err_msg then
                response.message = err_msg
            elseif result then
                response.body = result
            end
            self.on_raw_message("out", response)
            self:_send(response)
        end
        pcall(self.on_request, command, msg.arguments or {}, respond)
    end
end

---Write an encoded message to the adapter. Writing to a dead pipe or a closed
---socket raises, the one signal that the adapter is gone on a path with no
---response to wait for, so catch it and close instead of letting it escape.
---@param msg ndap.dap.Message
function Connection:_send(msg)
    local ok, err = pcall(self._write, transport.encode(msg))
    if not ok then
        self:close("adapter is gone (write failed: " .. tostring(err) .. ")")
    end
end

---Send a DAP request. Requests made on a closed connection fail their callback
---immediately rather than being queued for a response that will never come.
---@param command string
---@param args    table?
---@param cb      ndap.dap.ResponseCb?   called on response (or nil for fire-and-forget)
function Connection:request(command, args, cb)
    if self._closed then
        if cb then cb(nil, self._close_reason or "connection closed") end
        return
    end
    local seq = self:_next_seq()
    local msg = { type = "request", seq = seq, command = command }
    if args and next(args) ~= nil then
        msg.arguments = args
    end
    if cb then
        self._pending[seq] = cb
    end
    self.on_raw_message("out", msg)
    -- A failed write closes the connection, which drains `cb` from _pending.
    self:_send(msg)
end

---Tear down the underlying transport. Idempotent: safe from both the explicit
---stop path and every adapter-death path. on_close is scheduled *first*: a
---draining callback that raises must not take the session's end down with it.
---@param reason string?  why the connection ended; defaults to a plain close
function Connection:close(reason)
    if self._closed then return end
    self._closed = true
    self._close_reason = reason or "connection closed"
    vim.schedule(function() self.on_close(self._close_reason) end)
    local pending = self._pending
    self._pending = {}
    self._close()
    -- Drain so in-flight requests fail instead of hanging. This runs before the
    -- scheduled on_close either way, so the order above is only about safety.
    for _, cb in pairs(pending) do
        cb(nil, self._close_reason)
    end
end

-- Internal constructor

---@param opts ndap.dap.ConnOpts?
---@return ndap.dap.Connection
local function _new_conn(opts)
    ---@diagnostic disable-next-line: missing-fields
    return setmetatable({
        _seq           = 0,
        _pending       = {},
        _closed        = false,
        _close_reason  = nil,
        -- Replaced once the transport is up; until then (and after a transport
        -- failure) a write raises, which _send turns into a clean close.
        _write         = function() error("connection not established") end,
        _close         = function() end,
        on_event       = function() end,
        on_request     = function(_, _, respond) respond(nil, "unsupported request") end,
        on_close       = (opts and opts.on_close) or function() end,
        on_stderr      = function(_) end,
        on_raw_message = function() end,
    }, Connection)
end

-- stdio (pipe) connection

---Start the adapter as a subprocess and communicate via stdin/stdout.
---@param cmd  string[]       executable + arguments
---@param opts ndap.dap.StdioOpts?
---@return ndap.dap.Connection
function M.stdio(cmd, opts)
    opts              = opts or {}
    local conn        = _new_conn(opts)
    local parser      = transport.new_parser()

    parser.on_message = function(msg)
        -- jobstart callbacks fire on the main loop; dispatch synchronously.
        conn:_dispatch(msg)
    end

    local env         = nil
    if opts.env and next(opts.env) then env = opts.env end
    if opts.cwd and vim.fn.has("win32") == 0 then
        env = env and vim.deepcopy(env) or {}
        env.PWD = opts.cwd
    end

    local job_id = vim.fn.jobstart(cmd, {
        cwd       = opts.cwd,
        env       = env,
        -- Do NOT use stdout_buffered; we need streaming access.
        on_stdout = function(_, data)
            -- data is a list of strings split on \n.
            -- Joining with \n reconstructs the original bytes (including \r in \r\n sequences).
            local chunk = table.concat(data, "\n")
            if chunk ~= "" then
                parser:feed(chunk)
            end
        end,
        on_stderr = function(_, data)
            for _, line in ipairs(data) do
                if line ~= "" then
                    conn.on_stderr(line)
                end
            end
        end,
        -- The adapter process is gone: close with its exit status so the session
        -- terminates and the user is told why, whether it crashed or was stopped.
        on_exit   = function(_, code)
            local reason = (code == 0)
                and "adapter process exited"
                or ("adapter process exited with code " .. tostring(code))
            vim.schedule(function() conn:close(reason) end)
        end,
    })

    if job_id <= 0 then
        error("[dap] failed to start adapter: " .. table.concat(cmd, " "))
    end

    -- chansend returns 0 when the channel is gone; raising lets _send close down.
    conn._write = function(data)
        if vim.fn.chansend(job_id, data) == 0 then
            error("adapter stdin is closed")
        end
    end
    conn._close = function() vim.fn.jobstop(job_id) end

    return conn
end

-- TCP connection

---Attempt a single TCP connection; calls cb(conn, err) asynchronously.
---@param host string
---@param port integer
---@param opts ndap.dap.TcpOpts?
---@param cb   fun(conn: ndap.dap.Connection?, err: string?)
function M.try_tcp(host, port, opts, cb)
    opts = opts or {}
    local tcp = vim.uv.new_tcp()
    if not tcp then
        vim.schedule(function() cb(nil, "failed to create TCP handle") end)
        return
    end
    local conn = _new_conn(opts)

    local parser = transport.new_parser()
    parser.on_message = function(msg)
        vim.schedule(function() conn:_dispatch(msg) end)
    end
    -- A conn closed before the socket is up (never connected, or a crash during
    -- the attempt) must not try to touch the handle twice.
    conn._close = function()
        if not tcp:is_closing() then tcp:close() end
    end

    ---A failed attempt must not leak the handle it never used.
    ---@param err_msg string
    local function fail(err_msg)
        if not tcp:is_closing() then tcp:close() end
        vim.schedule(function() cb(nil, err_msg) end)
    end

    vim.uv.getaddrinfo(host, nil, { socktype = "stream" }, function(err, res)
        if err then
            fail(("DNS lookup failed: %s"):format(err))
            return
        end

        if not res or #res == 0 then
            fail("No addresses found")
            return
        end

        local ip = res[1].addr
        tcp:connect(ip, port, function(err)
            if err then
                fail(err)
                return
            end

            -- EOF (nil chunk) is how a crashed adapter reaches us over TCP: the
            -- kernel closes its socket. Either way the session must end.
            tcp:read_start(function(read_err, chunk)
                if read_err or not chunk then
                    local reason = read_err
                        and ("adapter connection error: " .. tostring(read_err))
                        or "adapter closed the connection"
                    vim.schedule(function() conn:close(reason) end)
                    return
                end
                parser:feed(chunk)
            end)

            conn._write = function(data)
                if tcp:is_closing() then error("adapter socket is closed") end
                assert(tcp:write(data))
            end
            conn._close = function()
                if tcp:is_closing() then return end
                tcp:read_stop()
                tcp:close()
            end
            conn.on_close = opts.on_close or function() end

            vim.schedule(function() cb(conn, nil) end)
        end)
    end)
end

return M
