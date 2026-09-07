---@class ndap.dap.Message
---@field type        "request"|"response"|"event"
---@field seq         integer
---@field command?    string    request/response command name
---@field event?      string    event name
---@field body?       table     response/event body
---@field arguments?  table     request arguments
---@field success?    boolean   response outcome
---@field message?    string    response error message
---@field request_seq? integer  response: echoes the originating request seq

---@class ndap.dap.Parser
---@field buf        string        accumulated raw bytes
---@field on_message fun(msg: ndap.dap.Message)  called for each complete decoded message
---@field feed       fun(self: ndap.dap.Parser, chunk: string)

local M = {}

---Create a new streaming parser.
---Feed raw bytes from the adapter into `parser:feed(chunk)`.
---`parser.on_message` is called (on the same thread) for each complete message.
---@return ndap.dap.Parser
function M.new_parser()
    ---@type ndap.dap.Parser
    ---@diagnostic disable-next-line: missing-fields
    local self = {
        buf = "",
        on_message = function(_) end,
    }

    ---@param chunk string  raw bytes received from the adapter
    function self:feed(chunk)
        self.buf = self.buf .. chunk
        while true do
            -- DAP uses Content-Length: N\r\n\r\n{body}
            -- jobstart splits on \n so we may see \r at line-ends; tolerate both separators.
            local sep, sep_end = self.buf:find("\r\n\r\n", 1, true)
            if not sep then
                sep, sep_end = self.buf:find("\n\n", 1, true)
            end
            if not sep then break end

            local header   = self.buf:sub(1, sep - 1)
            local body_len = tonumber(header:match("Content%-Length:%s*(%d+)"))
            if not body_len then
                -- Malformed header: discard up to end of separator and keep going
                self.buf = self.buf:sub(sep_end + 1)
            else
                local body_start = sep_end + 1
                local body_end   = body_start + body_len - 1
                if #self.buf < body_end then
                    break -- incomplete body, wait for more data
                end
                local raw = self.buf:sub(body_start, body_end)
                self.buf  = self.buf:sub(body_end + 1)
                local ok, msg = pcall(vim.json.decode, raw, {
                    luanil = { object = true, array = true },
                })
                if ok and type(msg) == "table" then
                    self.on_message(msg)
                end
            end
        end
    end

    return self
end

---Encode a message table as a Content-Length-framed DAP payload.
---@param msg ndap.dap.Message
---@return string
function M.encode(msg)
    local body = vim.json.encode(msg)
    return ("Content-Length: %d\r\n\r\n%s"):format(#body, body)
end

return M
