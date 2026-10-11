local OutputBuffer = require "ndap.ui.OutputBuffer"
local _config      = require("ndap.config").current
local ui_util      = require "ndap.util.ui"

---A debug task, native DAP, sent as-is. `request_args` is the adapter's raw
---launch/attach body, produced by a mode's `build`. This is the resolved shape
---`ndap.run.runner` runs, which run files and `:Ndap run` both produce via
---`ndap.run.schema`'s `resolve_task`.
---@class ndap.Task
---@field name?         string                     run group name (defaults to "debug")
---@field adapter       string                     an adapter name, see `ndap.available_adapters`
---@field mode?         string                     the mode this was resolved from, for the adapter's `setup`
---@field request?      "launch"|"attach"          defaults to "launch"
---@field request_args? table                      native DAP launch/attach body (the adapter's own keys), sent verbatim
---@field host?         string                     attach/TCP connection target
---@field port?         integer                    attach/TCP connection target (a mode's `build` or the adapter's `setup` supplies it)
---@field parameters?   table<string, any>         the mode's answered inputs, as `build` received them (see `ndap.AdapterSetupCtx`)

---Presentation options for a buffer registered with whoever is showing the run.
---@class ndap.AddBufOpts
---@field label?      string   tab label (defaults to the buffer name)
---@field priority?   integer  higher = surfaced preferentially when added (default 0)
---@field autoscroll? boolean  keep the buffer pinned to its last line while shown

---@class ndap.TaskCallback
---@field add_bufnr  fun(bufnr: integer, opts?: ndap.AddBufOpts)
---@field report     fun(message: string)
---@field on_done    fun(ok: boolean)

---@class ndap.TaskTypeDef
local M            = {}

-- Kinds the run names its own buffers by (the repl, the output, a terminal, the
-- raw `dap` trace, the run's log). A `setup` may not pass one to
-- `ctx.make_buf_name`: it would land on a buffer the run makes itself.
local _reserved_kinds = { repl = true, output = true, term = true, dap = true, log = true }

---The strict namer handed to a `setup`: same names as the run's own, but a
---reserved kind or a name already handed out errors rather than taking a `~1`
---suffix. `claimed` catches a second ask before its buffer exists to be found.
---@param run ndap.runner.Run
---@return fun(kind: string): string
local function make_setup_buf_name(run)
    local claimed = {}
    return function(kind)
        if _reserved_kinds[kind] then
            error(("buffer name %q is reserved for the run itself"):format(kind), 2)
        end
        local name = ui_util.run_buf_name(run.id, run.name, kind)
        if claimed[name] or ui_util.buf_name_taken(name) then
            error(("buffer name %q is already in use"):format(name), 2)
        end
        claimed[name] = true
        return name
    end
end

---@param task ndap.Task  native DAP task (name + adapter + request + request_args, plus optional host/port)
---@param callbacks ndap.TaskCallback
---@param run ndap.runner.Run  the run this task starts into, for naming the buffers it makes
---@return fun() -- cancel function
---@return integer[] -- ids of the sessions this run started, for its teardown
M.start            = function(task, callbacks, run)
    local add_bufnr = callbacks.add_bufnr or function() end
    local report    = callbacks.report or function() end
    local on_done   = callbacks.on_done or function() end

    local sessions  = {} ---@type table<integer, ndap.dap.Session>
    -- Every session this run produced, live or ended: what `dispose` answers for.
    local started   = {} ---@type integer[]

    local manager   = require("ndap.manager")

    ---A buffer name for this run of `kind`, unique against loaded buffers.
    ---@param kind string
    ---@return string
    local function buf_name(kind)
        return ui_util.unique_buf_name(ui_util.run_buf_name(run.id, run.name, kind))
    end

    local setup_buf_name = make_setup_buf_name(run)

    -- The task is native DAP: `request_args` is the adapter's raw launch/attach
    -- body, sent verbatim and never inspected or translated here. Scaffolding it
    -- from an adapter schema is new_run_file's job. No `request_args` sends an
    -- empty body.
    local base, load_err = require("ndap").load_adapter(task.adapter)
    if not base then
        report(load_err
            and ("DAP adapter " .. tostring(task.adapter) .. " failed to load: " .. load_err)
            or ("unknown DAP adapter: " .. tostring(task.adapter)))
        on_done(false)
        return function() end, {}
    end

    local request = task.request or "launch"

    -- Resolve the adapter definition + this task into the per-run dap config.
    -- setup/teardown stay on the adapter def (`base`); the runtime config carries
    -- only what the dap layer consumes. A definition's `command` outranks its host/port.
    local spawns = base.command ~= nil
    ---@type ndap.dap.Config
    local config = {
        name                = task.name,
        adapter             = task.adapter,
        type                = base.type,
        command             = base.command,
        cwd                 = base.cwd,
        env                 = base.env,
        defer_launch_attach = base.defer_launch_attach,
        host                = not spawns and base.host or nil,
        port                = not spawns and base.port or nil,
        request             = request,
        request_args        = vim.deepcopy(task.request_args or {}),
    }

    -- Applied before `setup`, which runs last and may overwrite both.
    if task.host ~= nil then config.host = task.host end
    if task.port ~= nil then config.port = task.port end

    -- REPL buffer: interactive DAP expression evaluation.
    local repl = require("ndap.ui.ReplBuffer").new({
        name     = buf_name("repl"),
        evaluate = function(expr, cb)
            manager.evaluate(expr, "repl", function(body, err)
                cb(body and body.result, err)
            end)
        end,
        complete = function(text, col, cb)
            manager.complete(text, col, cb)
        end,
    })
    add_bufnr(repl:bufnr(), { label = "repl", priority = -1 })

    -- Output buffer: created on first non-console output event.
    local out_buf = nil ---@type ndap.OutputBuffer?

    ---@param text string  output to append; may be multi-line
    local function append_output(text)
        local lines = vim.split(text, "\n", { plain = true })
        if lines[#lines] == "" then table.remove(lines) end
        if #lines == 0 then return end
        if not out_buf then
            out_buf = OutputBuffer.new({
                name        = buf_name("output"),
                max_lines   = _config.output_max_lines,
                ansi_colors = true,
                autoscroll  = true,
            })
            local buf = assert(out_buf:bufnr())
            add_bufnr(buf, { label = "output", priority = 0, autoscroll = true })
        end
        out_buf:append(lines)
    end

    local _cancel_early = false
    local unsub_progress ---@type fun()

    ---@type ndap.AdapterSetupCtx
    local _setup_ctx    = {
        add_bufnr     = add_bufnr,
        report        = report,
        mode          = task.mode,
        parameters    = task.parameters,
        make_buf_name = setup_buf_name,
    }

    -- Bound before `setup`: a failed one hands its state back with the error.
    local _teardown = base.teardown

    ---@param cb fun(state: any?, err: boolean?)  err is true only when setup failed
    local function _run_setup(cb)
        if not base.setup then return cb(nil) end
        _setup_ctx.report("setup: starting")
        base.setup(config, _setup_ctx, function(err, state)
            if err then
                vim.notify("[dap] setup failed: " .. tostring(err), vim.log.levels.ERROR)
                _setup_ctx.report("setup failed: " .. tostring(err))
                cb(state, true)
            else
                _setup_ctx.report("setup: ready")
                cb(state)
            end
        end)
    end

    _run_setup(function(setup_result, failed)
        if failed then
            -- A `setup` that gives up may still have started something; the state it
            -- hands back with the error is what stops it.
            if _teardown then pcall(_teardown, config, setup_result) end
            if unsub_progress then unsub_progress() end
            on_done(false)
            return
        end

        -- Nothing to spawn and nowhere to dial. Say so before starting, naming the
        -- mode, since the resolved config records neither; port 0 is the same as none.
        if config.command == nil and (config.port == nil or config.port == 0) then
            local where = task.mode
                and ("adapter %s mode %s"):format(task.adapter, task.mode)
                or ("adapter %s"):format(task.adapter)
            local msg = where .. ": no port to connect to and no command to spawn: "
                .. "nothing says how to reach the adapter"
            report(msg)
            vim.notify("[dap] " .. msg, vim.log.levels.ERROR)
            -- Setup succeeded but nothing will use what it made.
            if _teardown then pcall(_teardown, config, setup_result) end
            if unsub_progress then unsub_progress() end
            on_done(false)
            return
        end

        manager.start(config, {
            on_session = function(id, sess)
                sessions[id] = sess
                started[#started + 1] = id
                if _cancel_early then
                    sess:stop()
                    return
                end

                -- When the adapter spawns a terminal, name it as this run's `term`
                -- buffer and register it as a task buffer.
                sess:on("run_in_terminal", function(bufnr)
                    require("ndap.util.term").rename(bufnr, buf_name("term"))
                    vim.bo[bufnr].buflisted = true
                    add_bufnr(bufnr, { label = "term", priority = 10 })
                end)

                local unsub
                if _config.raw_messages then
                    local out ---@type ndap.OutputBuffer?
                    out = OutputBuffer.new({
                        name        = buf_name("dap"),
                        max_lines   = _config.output_max_lines,
                        ansi_colors = true,
                        autoscroll  = true,
                    })
                    local buf = assert(out:bufnr())
                    add_bufnr(buf, { label = "dap", priority = -3, autoscroll = true })
                    unsub = manager.on_raw_message:subscribe(function(sid, direction, msg)
                        if sid ~= id or not out:is_valid() then
                            unsub()
                            return
                        end
                        local arrow  = direction == "out" and "→" or "←"
                        local name   = msg.command or msg.event or ""
                        local header = ("%s [%s] %s"):format(arrow, msg.type or "?", name)
                        if msg.seq then header = header .. " #" .. msg.seq end
                        local ok, json = pcall(vim.json.encode, msg)
                        out:append({ header, ok and json or tostring(msg), "" })
                    end)
                end

                -- `reason` is set only when the adapter died on its own, which
                -- makes this run a failure rather than a finished one. Teardown
                -- runs either way; the adapter's own processes still need reaping.
                sess:on("terminated", function(_, reason)
                    sessions[id] = nil
                    if unsub then unsub() end
                    if unsub_progress then unsub_progress() end
                    if _teardown then pcall(_teardown, config, setup_result) end
                    on_done(reason == nil)
                end)
            end,
            on_fail = function()
                if unsub_progress then unsub_progress() end
                if _teardown then pcall(_teardown, config, setup_result) end
                on_done(false)
            end,
            on_event = function(event, ...)
                if event == "output" then
                    local category, text = ...
                    if category == "stdout" or category == "stderr" then
                        append_output(text)
                    elseif category ~= "telemetry" then
                        if category ~= "console" then
                            text = ("[%s] %s"):format(category, text)
                        end
                        repl:write(text)
                    end
                end
            end,
            on_progress = function(message)
                report(message)
            end,
        })
    end)

    local function cancel()
        if next(sessions) then
            for _, sess in pairs(sessions) do
                sess:stop()
            end
        else
            _cancel_early = true
        end
    end

    -- `started` is returned by reference: sessions land in it after this call.
    return cancel, started
end

return M
