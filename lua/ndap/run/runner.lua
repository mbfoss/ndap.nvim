---@brief Standalone task runner for ndap.
---
---Runs a debug task by supplying run callbacks to `ndap.run.task.start`, which
---stays provider-agnostic. Every run (`:Ndap start`, a run file, or another
---plugin's task) goes through here, so resolving a mode, tracking the run and
---cancelling it are written once.
---
---Every run is shown by a presenter (`ndap.runner.Presenter`), which takes its
---buffers, its progress and its outcome. ndap's own runs get the presenter
---`setup` installs; a caller may pass its own and show the run itself. Nothing
---here knows about windows either way.
---
---Who shows a run is separate from who owns it: an `owned` run is ndap's to tidy
---through `clean` and to replace when its task is re-run, while a run a caller
---presents leaves only through `remove`.
---
---One task per file: a run file returns a single task (or a function
---returning one):
---  -- debug.lua
---  return { name = "debug app", adapter = "lldb", mode = "binary", parameters = { program = "a.out" } }

local M = {}

---@alias ndap.runner.RunState "running"|"done"|"failed"

---One buffer a run spawned, together with how it asked to be presented.
---@class ndap.runner.RunBuffer
---@field bufnr integer
---@field opts  ndap.AddBufOpts

---A run: a unique number, the task name, a cancel function, whoever is showing
---it and how it is faring. Runs are tracked together so tasks can run in parallel.
---@class ndap.runner.Run
---@field id        integer  the run number, unique per session; names the run's buffers
---@field name      string
---@field cancel    fun()
---@field sessions  integer[]  the sessions this run started, filled in as they start
---@field state     ndap.runner.RunState
---@field owned     boolean  whether this run's lifetime is ndap's: what `clean` and re-running act on
---@field presenter ndap.runner.Presenter  whoever shows this run: ndap's own display, or a caller's
---@field settled?  boolean  whether the presenter has been told how the run ended

---Whoever shows a run: it takes the run's buffers, progress and outcome through
---these callbacks, the same ones `ndap.run.task` speaks, and disposes of what it
---made when the run is forgotten.
---@class ndap.runner.Presenter : ndap.TaskCallback
---@field name?       string  run group name (defaults to the adapter's)
---@field on_removed? fun()  the run being forgotten, while its buffers are still valid

---@alias ndap.runner.PresenterFactory fun(run: ndap.runner.Run): ndap.runner.Presenter

---The presenter ndap gives the runs it owns. Until `setup` installs the real one
---a run still starts and its sessions still attach; there is just nowhere for it
---to show.
---@type ndap.runner.PresenterFactory
local _presenter_for = function()
    return { add_bufnr = function() end, report = function() end, on_done = function() end }
end

---Install the presenter ndap's own runs are shown by. Called from `setup`, which
---picks the panel behind it.
---@param factory ndap.runner.PresenterFactory
function M.set_presenter(factory) _presenter_for = factory end

---@type ndap.runner.Run[]
local _runs    = {}
local _counter = 0

---The most recently run task, kept so `rerun()` can start it again from scratch.
---@type ndap.Task?
local _last_task

---@param msg string
local function _warn(msg) vim.notify("[ndap] " .. msg, vim.log.levels.WARN) end

---@param msg string
local function _err(msg) vim.notify("[ndap] " .. msg, vim.log.levels.ERROR) end

---@param v any
---@return boolean
local function _is_task(v)
    return type(v) == "table" and type(v.adapter) == "string"
end

---Tell a run's presenter the run is gone, while the buffers it holds are still
---valid. Disposing of them is the presenter's job: ndap's own wipes them, a
---caller's does whatever it does.
---@param run ndap.runner.Run
local function _remove_run(run)
    if run.presenter.on_removed then run.presenter.on_removed() end
end

---Drop any finished run of the same name and wipe its buffers, so re-running a
---task replaces its own previous run. Live runs and finished runs of other tasks
---are left untouched, so parallel runs accumulate independently.
---@param name string
local function _clear_finished(name)
    local kept = {}
    for _, r in ipairs(_runs) do
        if r.state ~= "running" and r.name == name and r.owned then
            _remove_run(r)
        else
            kept[#kept + 1] = r
        end
    end
    _runs = kept
end

---Forget a single run, letting its presenter dispose of what it made. A live run
---is not stopped first; cancel it before removing it.
---@param run ndap.runner.Run
function M.remove(run)
    for i, r in ipairs(_runs) do
        if r == run then
            table.remove(_runs, i)
            break
        end
    end
    _remove_run(run)
end

---Drop every finished run ndap owns and wipe their buffers, leaving live runs,
---and every run a caller presents, which is that caller's to drop, untouched.
---Bound to `:Ndap clean`.
function M.clean()
    local kept, finished = {}, {}
    for _, r in ipairs(_runs) do
        if r.state ~= "running" and r.owned then
            finished[#finished + 1] = r
        else
            kept[#kept + 1] = r
        end
    end
    _runs = kept
    for _, r in ipairs(finished) do
        _remove_run(r)
    end
end

---Create and track a run, and give it the presenter it reports into. A run
---without a `presenter` of its own is ndap's: it is owned here and shown by the
---presenter `setup` installed.
---@param name string  run group name
---@param presenter? ndap.runner.Presenter
---@return ndap.runner.Run
local function _new_run(name, presenter)
    _clear_finished(name)

    _counter          = _counter + 1
    -- `presenter` is filled in just below: it needs the run to exist first.
    ---@diagnostic disable-next-line: missing-fields
    local run         = {
        id       = _counter,
        name     = name,
        cancel   = function() end,
        sessions = {},
        state    = "running",
        owned    = presenter == nil,
    } --[[@as ndap.runner.Run]]
    -- Built from the run so it has the identity to show it by, and built before
    -- anything can report into it: making the run's log is the presenter's own
    -- first act.
    run.presenter     = presenter or _presenter_for(run)
    _runs[#_runs + 1] = run
    return run
end

---Record how a run is faring and tell its presenter how it ended.
---@param run ndap.runner.Run
---@param state ndap.runner.RunState
local function _set_state(run, state)
    run.state = state
    -- `on_done` is a one-shot contract and says how the run ended by itself:
    -- whatever ends after it (a second session, a late cancel) is no longer the
    -- presenter's business.
    if run.settled then return end
    run.settled = true
    run.presenter.on_done(state == "done")
end

---Start a resolved task into a run that already exists, wiring up the callbacks
---it reports through and taking over its `cancel`.
---@param run ndap.runner.Run
---@param task ndap.Task
local function _start(run, task)
    -- `rerun` re-launches into ndap's own UI; a run a caller presents is that
    -- caller's to repeat.
    if run.owned then _last_task = task end

    local cancel, sessions = require("ndap.run.task").start(task, {
        -- Buffers and progress go straight to the presenter, which holds them; only
        -- the outcome is recorded here first.
        add_bufnr = run.presenter.add_bufnr,
        report    = run.presenter.report,
        on_done   = function(ok) _set_state(run, ok and "done" or "failed") end,
    }, run)

    run.cancel             = cancel
    -- Held by reference: the sessions land in it as they start.
    run.sessions           = sessions
end

---Resolve one of an adapter's named modes through its `build` and run it. The run
---exists before `build` is asked anything, so a mode that stops to ask the user
---something still has a run to report into and a `cancel` that calls the question
---off, where a resolve that never answers would otherwise leave nothing to stop.
---@param spec ndap.ResolveSpec  `name` is the run group name, defaulting to the adapter's
---@param presenter? ndap.runner.Presenter
---@return ndap.runner.Run
local function _start_spec(spec, presenter)
    local run = _new_run(spec.name or spec.adapter, presenter)

    -- Cancelling while the mode is still resolving calls the question off and fails
    -- the run. It goes on before resolving, not after: a mode that asks nothing
    -- resolves and starts inside the call below, and `_start` must have the last
    -- word on `cancel`: that one has a session to stop.
    local cancel_resolve
    run.cancel = function()
        if cancel_resolve then cancel_resolve() end
        if run.state == "running" then _set_state(run, "failed") end
    end

    cancel_resolve = require("ndap.run.schema").resolve_task(spec, function(task, err)
        -- Cancelled while resolving: the run is already settled and nothing starts.
        if run.state ~= "running" then return end
        if not task then
            local msg = ("run: %s: %s"):format(run.name, tostring(err))
            run.presenter.report(msg)
            -- A caller's presenter shows its own log; only ndap's runs need the notify.
            if run.owned then _err(msg) end
            return _set_state(run, "failed")
        end
        _start(run, task)
    end)

    return run
end

---Start a new run from the most recently run task's configuration, skipping the
---resolve it already went through. Unlike `:Ndap restart` (a DAP request on the
---live session) this works after the session has ended and for adapters without
---restart support. Runs alongside the others: it replaces its own previous
---finished run, not theirs. Warns when no task has been run yet.
---@return ndap.runner.Run?
function M.rerun()
    if not _last_task then
        _warn("rerun: nothing to rerun yet (start a run first)")
        return
    end
    -- Copied because `_start` records it as the task to rerun next time, and the
    -- one held here must not be the one a run is mutating.
    local task = vim.deepcopy(_last_task)
    local run  = _new_run(task.name or "debug")
    _start(run, task)
    return run
end

---Prompt to pick one of the Lua files directly in `dir`, then start it, using
---ndap's own fuzzy picker with a preview of each file. Starts the sole file
---outright when there is only one, and warns when there are none.
---@param dir string  absolute directory path
local function _start_from_dir(dir)
    local files = vim.fn.globpath(dir, "*.lua", true, true) ---@type string[]
    if #files == 0 then
        _warn("start_file: no Lua files in " .. dir)
        return
    end
    local items = {}
    for _, f in ipairs(files) do
        items[#items + 1] = {
            chunks = { { vim.fn.fnamemodify(f, ":t")} },
            data   = { filepath = f },
        }
    end
    require("ndap.util.select").open({
        prompt         = "Debug task",
        items          = items,
        enable_preview = true,
    }, function(data)
        if data and data.filepath then M.start_file(data.filepath) end
    end)
end

---Start a task from a path: a directory opens a picker of its Lua files, a Lua file
---is loaded and the value it returns is started: a mode-based task (`adapter`/
---`mode`/`parameters`), resolved through the mode's `build`.
---@param path string
---@return ndap.runner.Run?  nil when the path yields no task to start
function M.start_file(path)
    if type(path) ~= "string" or path == "" then
        _warn("start_file: no path given (usage: start_file('path/to/task.lua' or a folder))")
        return
    end

    local resolved = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
    ---@diagnostic disable-next-line: undefined-field
    local stat     = vim.uv.fs_stat(resolved)
    if not stat then
        _warn("start_file: path not found: " .. resolved)
        return
    end
    if stat.type == "directory" then
        return _start_from_dir(resolved)
    end
    if not resolved:match("%.lua$") then
        _warn("start_file: not a Lua file: " .. resolved)
        return
    end

    local chunk, load_err = loadfile(resolved)
    if not chunk then
        _err("start_file: cannot load " .. resolved .. ": " .. tostring(load_err))
        return
    end

    local ok, spec = pcall(chunk)
    if ok and type(spec) == "function" then
        ok, spec = pcall(spec)
    end
    if not ok then
        _err("start_file: error in " .. resolved .. ": " .. tostring(spec))
        return
    end

    if not _is_task(spec) then
        _err("start_file: " .. vim.fn.fnamemodify(resolved, ":t") ..
            " must return a task table with an `adapter` field")
        return
    end

    -- A mode-based run file names a mode and answers its inputs under
    -- `parameters`; resolve it through the mode's `build`, as `:Ndap start` does.
    if type(spec.mode) == "string" then
        return _start_spec({
            adapter    = spec.adapter,
            mode       = spec.mode,
            name       = spec.name or vim.fn.fnamemodify(resolved, ":t"),
            parameters = spec.parameters,
        })
    end

    _err("start_file: " .. vim.fn.fnamemodify(resolved, ":t") .. " must set `mode` (a named mode)")
end

---Launch or attach under an adapter's named mode, resolving `parameters` (the
---answers to the mode's declared inputs, in their typed form; a number is a
---number, not text) through `schema.resolve_task`. The run is returned right away,
---even when `build` stops to ask the user something: it starts, or fails, once
---they answer.
---@param adapter string  adapter name, e.g. "codelldb"
---@param mode_name string  mode name, e.g. "binary"
---@param parameters? table<string, any>  input name -> value, e.g. { program = "./a.out" }
---@param presenter? ndap.runner.Presenter  a caller showing the run in a UI of its own
---@return ndap.runner.Run?
function M.start_mode(adapter, mode_name, parameters, presenter)
    local schema = require("ndap.run.schema")

    if not adapter or adapter == "" then
        _warn("start: usage: :Ndap start <adapter> <mode> [--input value …]")
        return
    end
    local def, load_err = require("ndap").load_adapter(adapter)
    if not def then
        _err("start: " .. (load_err and ("adapter " .. adapter .. " failed to load: " .. load_err)
            or ("unknown adapter: " .. adapter .. " (available: "
                .. table.concat(require("ndap").available_adapters(), ", ") .. ")")))
        return
    end
    if not mode_name or mode_name == "" then
        _warn("start: usage: :Ndap start " .. adapter .. " <mode> [--input value …]"
            .. " (modes: " .. table.concat(schema.mode_names(adapter), ", ") .. ")")
        return
    end

    return _start_spec({
        adapter    = adapter,
        mode       = mode_name,
        name       = (presenter and presenter.name) or adapter,
        parameters = parameters or {},
    }, presenter)
end

---Cancel every live run. Stops their sessions, or aborts a run still in adapter
---setup (before any session exists, where `:Ndap stop` has nothing to act on yet).
function M.cancel()
    for _, r in ipairs(_runs) do
        if r.state == "running" then r.cancel() end
    end
end

return M
