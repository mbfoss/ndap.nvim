---@brief Schema engine behind `:Ndap new_run_file` and `:Ndap start`.
---
---Adapters carry no launch/attach schema of their own; each adapter's
---`modes` (named `ndap.Mode` entries, in `ndap.adapters`)
---are wholly self-describing. A mode declares its inputs up front in an
---`inputs` table (`name -> ndap.Input`), which both `:Ndap start` and a
---scaffolded run file read, then resolve the same way: `resolve_task` runs the
---mode's `build` over the supplied parameters to assemble a runnable task.
---

local inputs_registry = require("ndap.run.inputs")

local M = {}

-- Introspection

---An adapter's declared `modes`, or an empty table. Loads the definition.
---@param adapter string
---@return table<string, ndap.Mode>
local function _modes(adapter)
    local def = require("ndap").load_adapter(adapter)
    return (def and def.modes) or {}
end

---A single named mode, or nil.
---@param adapter string
---@param name string
---@return ndap.Mode?
function M.mode(adapter, name)
    return _modes(adapter)[name]
end

---An adapter's mode names, sorted.
---@param adapter string
---@return string[]
function M.mode_names(adapter)
    local out = {}
    for name in pairs(_modes(adapter)) do out[#out + 1] = name end
    table.sort(out)
    return out
end

---The inputs a mode declares (`name -> ndap.Input`), or an empty table. Hand an
---entry to `ndap.run.inputs` to learn how to read, describe, seed or complete it; read
---the table once rather than looking entries up name-by-name.
---@param adapter string
---@param mode_name string
---@return table<string, ndap.Input>
function M.mode_inputs(adapter, mode_name)
    local mode = M.mode(adapter, mode_name)
    return (mode and mode.inputs) or {}
end

---The input names a mode declares, sorted. These are the `--name` flags
---`:Ndap start` accepts, and the `parameters` keys a tasks file may set.
---@param adapter string
---@param mode_name string
---@return string[]
function M.mode_input_names(adapter, mode_name)
    local out = {}
    for name in pairs(M.mode_inputs(adapter, mode_name)) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

---The input names a mode marks `required = true`, sorted: the ones
---`resolve_task` errors on when left unset.
---@param adapter string
---@param mode_name string
---@return string[]
function M.mode_required(adapter, mode_name)
    local out = {}
    for name, spec in pairs(M.mode_inputs(adapter, mode_name)) do
        if spec.required then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

-- Validation

---One mode's declaration problems, each already prefixed with the mode name.
---@param adapter string
---@param mode_name string
---@param out string[]  appended to
local function _check_mode(adapter, mode_name, out)
    local mode = M.mode(adapter, mode_name)
    if not mode then
        out[#out + 1] = mode_name .. ": not declared"
        return
    end
    local function problem(fmt, ...) out[#out + 1] = mode_name .. ": " .. fmt:format(...) end

    if mode.request ~= "launch" and mode.request ~= "attach" then
        problem("request is %s, expected \"launch\" or \"attach\"", vim.inspect(mode.request))
    end
    if type(mode.description) ~= "string" or mode.description == "" then
        problem("no description")
    end
    if mode.build ~= nil and type(mode.build) ~= "function" then
        problem("build is %s, expected a function", type(mode.build))
    end
    if mode.inputs ~= nil and type(mode.inputs) ~= "table" then
        problem("inputs is %s, expected a table", type(mode.inputs))
        return
    end

    for _, name in ipairs(M.mode_input_names(adapter, mode_name)) do
        local spec = M.mode_inputs(adapter, mode_name)[name]
        local err = inputs_registry.check(spec)
        if err then problem("input %s: %s", name, err) end
    end

end

---Everything wrong with one registered adapter's definition, as messages: a
---file that does not load, a mode that requests neither launch nor attach, an
---input that cannot be read. An empty list is a definition that resolves, not
---one that runs: whether its tooling is in place is `:Ndap adapter_info`.
---@param adapter string
---@return string[] problems
function M.validate(adapter)
    local def, err = require("ndap").load_adapter(adapter)
    if def == nil then
        -- A definition whose file did not load leaves nothing to walk; say why
        -- rather than let the name go missing.
        return { err and ("failed to load: " .. tostring(err)) or "not registered" }
    end
    if type(def) ~= "table" then
        return { ("not a table, got %s"):format(type(def)) }
    end

    local out = {}
    -- Reachability is not static: a mode's `build` supplies the connection at run
    -- time, so only a definition with no `build` anywhere is unreachable for certain.
    -- One whose `build` returns no connection is caught before the run starts.
    local reachable = def.command ~= nil or def.host ~= nil or def.port ~= nil
        or def.setup ~= nil
    if not reachable and type(def.modes) == "table" then
        for _, mode in pairs(def.modes) do
            if type(mode) == "table" and mode.build ~= nil then
                reachable = true
                break
            end
        end
    end
    if not reachable then
        out[#out + 1] =
            "no command, host/port or setup, and no mode with a build: nothing says how to reach the adapter"
    end

    local names = M.mode_names(adapter)
    if #names == 0 then
        out[#out + 1] = "declares no modes: `:Ndap start` cannot reach it"
    end
    for _, name in ipairs(names) do _check_mode(adapter, name, out) end
    return out
end

-- Resolving

---Read every declared input from `parameters`, each as the Lua value it is (a
---collection's table included). The string form belongs to the command line, which
---`parse`s it before calling here, so a number or a boolean given as text is
---refused. Unset inputs are absent, and a name the mode declares nothing for is an
---error, not a value quietly dropped.
---@param mode ndap.Mode
---@param parameters table<string, any>  input name → a value in its typed form
---@return table<string, any> out, string[] missing, string[] errs
local function _read_inputs(mode, parameters)
    local out, missing, errs = {}, {}, {}
    local declared = {}
    for name, spec in pairs(mode.inputs or {}) do
        declared[name] = true
        local raw = parameters[name]
        -- An input cleared rather than answered (an empty string) is one that was
        -- not supplied: `build` assigns it unconditionally, and only nil drops the field.
        if raw == nil or raw == "" then
            if spec.required then missing[#missing + 1] = name end
        else
            local val, cerr = inputs_registry.read(spec, raw)
            if cerr then
                errs[#errs + 1] = name .. ": " .. cerr
            else
                out[name] = val
            end
        end
    end
    -- A name no input answers to (a mistyped `:Ndap start … --name`, a run file's
    -- `parameters`, a caller's table) is read by nothing, so `build` would never see
    -- it. Refused rather than dropped, the way a value that will not parse is.
    local unknown = {}
    for name in pairs(parameters) do
        if not declared[name] then unknown[#unknown + 1] = name end
    end
    if #unknown > 0 then
        table.sort(unknown)
        errs[#errs + 1] = ("unknown input name%s: %s"):format(
            #unknown == 1 and "" or "s",
            table.concat(vim.tbl_map(function(n) return ("%q"):format(n) end, unknown)))
    end
    -- `pairs` order is arbitrary; sort so the reported set is stable.
    table.sort(missing)
    table.sort(errs)
    return out, missing, errs
end

---What to resolve: an adapter's named mode, the parameters answering its inputs,
---and the name the resulting task should run under.
---@class ndap.ResolveSpec
---@field adapter       string
---@field mode string
---@field name?         string              run group name for the resolved task
---@field parameters?   table<string, any>  input name → a value in its typed form

---Resolve one of an adapter's named modes, plus parameters answering its inputs,
---into a
---runnable `ndap.Task`: request kind and any task-level connection already in
---place. This is the single seam between a mode and a front end.
---@param spec ndap.ResolveSpec
---@param done fun(task: ndap.Task?, err: string?)
---@return fun() cancel
function M.resolve_task(spec, done)
    local settled, cancelled = false, false

    ---@param task ndap.Task?
    ---@param err string?
    local function finish(task, err)
        if settled or cancelled then return end
        done(task, err)
        settled = true -- set after done() because it may fail and settle with error
    end

    local function cancel() cancelled = true end

    local mode = M.mode(spec.adapter, spec.mode)
    if not mode then
        finish(nil, ("adapter %s has no mode %q (available: %s)")
            :format(spec.adapter, tostring(spec.mode),
                table.concat(M.mode_names(spec.adapter), ", ")))
        return cancel
    end

    local parameters, missing, errs = _read_inputs(mode, spec.parameters or {})
    if #errs > 0 then
        finish(nil, table.concat(errs, "; "))
        return cancel
    end
    if #missing > 0 then
        finish(nil, "missing: " .. table.concat(missing, ", "))
        return cancel
    end

    ---Package what `build` returned into the task it describes.
    ---@param body table  the DAP request body
    ---@param connect table  the host/port the run should dial, possibly empty
    local function deliver(body, connect)
        -- `connect` is task-level, not a body field. An empty one reports none, leaving
        -- the AdapterDef's own host/port in force.
        local has_connect = next(connect) ~= nil
        finish({
            name         = spec.name,
            adapter      = spec.adapter,
            mode         = spec.mode,
            request      = mode.request,
            request_args = body,
            host         = has_connect and connect.host or nil,
            port         = has_connect and connect.port or nil,
            parameters   = parameters,
        })
    end

    -- A mode with no `build` takes no parameters into the body: the request goes out bare.
    if not mode.build then
        deliver({}, {})
        return cancel
    end

    local co = coroutine.create(function()
        local ok, body, connect = xpcall(mode.build, debug.traceback, parameters)
        -- `build` raised: `body` holds the traceback the handler produced.
        if not ok then return finish(nil, tostring(body)) end
        -- `build` gave up and named why in the slot a successful call returns
        -- `connect` in. Only a string is a reason; a table renders as `table: 0x…`.
        if body == nil then
            if type(connect) == "string" then return finish(nil, connect) end
            return finish(nil, "build produced no request body")
        end
        if type(body) ~= "table" then
            return finish(nil, ("build returned a %s, expected the request body"):format(type(body)))
        end
        if connect ~= nil and type(connect) ~= "table" then
            return finish(nil, ("build returned a %s as its connection, expected a table")
                :format(type(connect)))
        end
        deliver(body --[[@as table]], connect --[[@as table]] or {})
    end)
    local ok, err = coroutine.resume(co)
    if not ok then finish(nil, tostring(err)) end

    return cancel
end

return M
