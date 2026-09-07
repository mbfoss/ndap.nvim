-- Generic TCP attach: connect to a DAP server already listening on host:port.
-- Nothing here spawns or dials by itself: the `connect` mode's `build` is the only
-- source of the connection, and the attach body stays minimal. The one adapter ndap
-- ships.

local shared = require("ndap.shared")

---@type ndap.AdapterDef
return {
    modes = {
        connect = {
            description = "attach to a DAP server listening on host:port",
            request     = "attach",
            inputs      = {
                host = {
                    type = "string", description = "DAP server host (default 127.0.0.1)",
                    completion = { "localhost", "127.0.0.1", "::1", "::" },
                },
                port = { type = "integer", description = "DAP server port" },
            },
            build = function(parameters)
                local port, err = shared.resolve_port(parameters.port)
                if err then return nil, err end
                return {}, { host = parameters.host or "127.0.0.1", port = port }
            end,
        },
    },
}
