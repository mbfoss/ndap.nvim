---The fields are declared in [meta.lua](meta.lua); binding the table to that class
---is what makes a mismatched `M.foo` below a diagnostic rather than a silent drift.
---@type ndap.Module
local M = {}

local COMMAND = "Ndap"

-- Whether `setup()` has run. The public API relies on the config, command and
-- autocmds it installs; calling in before then would silently do the wrong
-- thing, so those entry points fail loudly instead.
local _setup_done = false

-- Whether the plugin proper is up: UI wiring, DAP subscriptions and the
-- restored project state. `setup()` deliberately stops short of this, so a
-- session that never debugs pays for nothing beyond the command and autocmds.
local _loaded = false
---Defined below, once `_init` is in scope.
---@type fun()
local _ensure_loaded

--- The live options: read an option off it directly
--- (`require("ndap").config.inline_vars`). `setup()` refills this same table,
--- so holding it is safe; copying an option out of it is not.
M.config = require("ndap.config").current

---The loaded DAP adapter definitions, `name → ndap.AdapterDef`: a plain table,
---filled as definitions are read (`load_adapter`), and one a user may assign
---into directly to register an adapter by hand, no file needed.
---`available_adapters()` is the list of what can be loaded.
M.adapters = {}

---Guard a public API entry point: raise a clear error, pointed at the caller,
---when `setup()` has not been called yet. Otherwise this *is* the demand that
---brings the plugin up, so every entry point below can assume a loaded plugin.
---@param fn string  the API name, for the message
local function _require_setup(fn)
    if not _setup_done then
        error(("[ndap] require('ndap').setup() must be called before %s()"):format(fn), 3)
    end
    _ensure_loaded()
end

---Whether the current project has a state file on disk. Deliberately goes to
---`project` rather than `store`: this runs while cold, and `store` would drag
---the read/write machinery in behind it. Nothing is decoded.
---@return boolean
local function _has_saved_state()
    local path = require("ndap.project").data_path()
    return path ~= nil and vim.uv.fs_stat(path) ~= nil
end

-- Persistence seam: the engine deals in absolute source paths; on-disk state
-- uses project-relative paths for portability. The path conversion lives here,
-- never in the engine or the store.

---Collect breakpoints/expressions into a single on-disk payload, relativizing
---breakpoint source paths.
---@return table
local function _collect()
    local store       = require("ndap.store")
    local bps         = require("ndap.dap.breakpoints")
    local exprs       = require("ndap.ui.expressions")
    local breakpoints = bps.get_data()
    for _, bp in ipairs(breakpoints.source) do bp.source = store.relativize(bp.source) end
    return { breakpoints = breakpoints, expressions = exprs.get_data() }
end

---Persist the current project's breakpoints/expressions. No-op when rootless.
local function _save()
    local store = require("ndap.store")
    if not store.root() then return end
    store.write(_collect())
end

---Restore breakpoints/expressions for the current project, absolutizing
---breakpoint source paths. Clears them when the cwd is not in a project.
local function _load()
    local store       = require("ndap.store")
    local bps         = require("ndap.dap.breakpoints")
    local exprs       = require("ndap.ui.expressions")
    local data        = store.read() or {}
    local breakpoints = data.breakpoints
    if type(breakpoints) == "table" and type(breakpoints.source) == "table" then
        for _, bp in ipairs(breakpoints.source) do bp.source = store.absolutize(bp.source) end
    end
    bps.restore(breakpoints)
    exprs.restore(data.expressions)
end

-- Whether we've already warned, in the current rootless stretch, that project
-- state can't be persisted. Reset on every cwd change so a later rootless period
-- warns afresh.
local _warned_rootless = false

---Warn, once per rootless stretch, that the breakpoint/expression set changed
---but won't be persisted, because the cwd is not inside a project. No-op inside a
---project, or while nothing is set (so it never fires on an empty startup).
local function _warn_if_unpersisted()
    if _warned_rootless then return end
    if require("ndap.store").root() then return end
    local bps   = require("ndap.dap.breakpoints")
    local exprs = require("ndap.ui.expressions")
    if #bps.all() == 0 and #bps.function_breakpoints() == 0
        and #bps.exception_name_breakpoints() == 0 and #exprs.all() == 0 then
        return
    end
    _warned_rootless = true
    vim.notify(
        "[ndap] not in a project (no root marker); breakpoints and watch expressions won't be persisted",
        vim.log.levels.WARN)
end

-- The `:Ndap` command line -- parsing, routing and completion -- is
-- implemented in `ndap.usercmd`, required lazily from the callback below so init
-- only pays for it once the command is first used.

-- Autocmd handlers. `setup()` creates the autocmds, so these fire from then
-- on, including in a session that never brought the plugin up. Each one is a
-- no-op while cold: there are no breakpoints, expressions or sessions yet.

---Persist the current project's breakpoints and expressions.
function M.save_state()
    if not _loaded then return end
    _save()
end

---Re-resolve the project root after a cwd change and restore that project's
---state (or clear it, when the new cwd is not inside a project).
function M.reload_state()
    require("ndap.project").invalidate()
    _warned_rootless = false

    -- Still cold: the new project's state file is the trigger, exactly as at
    -- `setup()`. Without one there is nothing to restore and nothing to clear.
    if not _loaded then
        if _has_saved_state() then _ensure_loaded() end
        return
    end

    _load()
    -- The reloaded state belongs to another project; undoing into it would
    -- resurrect the old one's breakpoints.
    local view = require("ndap.commands").view.debug_view_if_open()
    if view then view:clear_undo() end
end

---Disconnect every live session on exit: an adapter killed without a completed
---`disconnect` orphans its debuggee, and nvim SIGKILLs adapter jobs as it exits.
---vim.wait pumps the loop for the responses; the timeout caps a hung adapter.
function M.shutdown()
    if not _loaded then return end
    local client = require("ndap.dap.client")
    local done = false
    client.quit(function() done = true end)
    vim.wait(10000, function() return done end, 20)
end

---Wire up the UI and DAP subscriptions. Called once, via `_ensure_loaded`.
local function _init()
    require("ndap.dap.breakpoints").on_change:subscribe(_warn_if_unpersisted)
    require("ndap.ui.expressions").on_change:subscribe(_warn_if_unpersisted)

    require("ndap.ui.breakpoints_ui").init()
    require("ndap.ui.debugline_ui").init()
    require("ndap.ui.inlinevars").enable()
    require("ndap.ui.popup_menu").init()
    -- The one place picking the panel: ndap's bottom split, which shows a
    -- run's highest-priority buffer.
    local panel = require("ndap.ui.Panel")
    panel.init()

    -- Every run ndap owns is shown through `run_display`, onto that panel.
    require("ndap.run.runner").set_presenter(
        require("ndap.ui.run_display").for_panel(panel))

    local client = require("ndap.dap.client")
    client.on_session_added:subscribe(function()
        vim.schedule(function() require("ndap.commands").view.debug_view():show() end)
    end)
end

---Bring the plugin proper up, once. The two demands that reach here are a
---`:Ndap` invocation (or any public API call) and a project state file found
---by `setup()` or a cwd change.
function _ensure_loaded()
    if _loaded then return end
    _loaded = true
    _init()
    _load()
end

-- The view singletons are in `commands` (they are a command concern); these are
-- the guarded public entry points onto them.

---Open the DebugView in a vertical split (or focus if already visible).
function M.open_debug_view()
    _require_setup("open_debug_view")
    require("ndap.commands").view.open()
end

---Close the DebugView if it is visible. No-op when it is not.
function M.close_debug_view()
    _require_setup("close_debug_view")
    require("ndap.commands").view.hide()
end

---Close the DebugView if it is visible, otherwise open and focus it.
function M.toggle_debug_view()
    _require_setup("toggle_debug_view")
    require("ndap.commands").view.toggle()
end

---Open the disassembly pane for the active session's current frame.
function M.open_disassembly_view()
    _require_setup("open_disassembly_view")
    require("ndap.commands").view.disassembly_view():open()
end

---@param path string a Lua file returning a single task, or a folder to pick one from
function M.start_file(path)
    _require_setup("start_file")
    M.clean()
    local runner = require("ndap.run.runner")
    return runner.start_file(path)
end

---Write a run_file for one of an adapter's modes (`adapter`/`mode`/
---`parameters`, seeded and commented) and open it for editing. `assignments` is
---positional: adapter, optional mode (defaults to the sole one), optional path.
---@param assignments string[]  positional adapter, mode, path, e.g. { "codelldb", "binary", "./foo.lua" }
function M.new_run_file(assignments)
    _require_setup("new_run_file")
    return require("ndap.run.scaffold").new_run_file(assignments)
end

-- The adapter registry. Definitions are files found by name on the runtimepath
-- and read one at a time, so nothing is loaded until an adapter is asked for by
-- name; what has been read is kept in `ndap.adapters`.

---Every `ndap-adapters/*.lua` on the runtimepath, `name → path`.
---@type table<string, string>?
local _definition_paths

---@return table<string, string>
local function _definitions()
    if _definition_paths then return _definition_paths end
    _definition_paths = {}
    for _, path in ipairs(vim.api.nvim_get_runtime_file("ndap-adapters/*.lua", true)) do
        local name = vim.fn.fnamemodify(path, ":t:r")
        -- Runtimepath order, so the first match for a name shadows any later one: a
        -- definition in your config overrides the plugin's.
        if not _definition_paths[name] then _definition_paths[name] = path end
    end
    return _definition_paths
end

---Whether `name` survives the `enabled_adapters` filter. Unset, the default,
---lets every name through; a list narrows the registry to exactly those names,
---whether they come from a definition file or from `ndap.adapters`.
---@param name string
---@return boolean
local function _enabled(name)
    local allowed = M.config.enabled_adapters
    return allowed == nil or vim.tbl_contains(allowed, name)
end

---Every adapter that can be run, sorted: each definition file on the
---runtimepath, named by its filename stem, plus anything registered by hand in
---`ndap.adapters`, narrowed to `enabled_adapters` when that is set. Naming them
---reads no definition.
---
---A projection, not an entry point: it needs no `setup()` and brings nothing
---up, so a caller can ask before one has run. Only the `enabled_adapters`
---filter comes from `setup()`, and unset it lets every name through.
---@return string[]
function M.available_adapters()
    local out, seen = {}, {}
    local function add(name)
        if not seen[name] and _enabled(name) then out[#out + 1], seen[name] = name, true end
    end
    for name in pairs(_definitions()) do add(name) end
    for name in pairs(M.adapters) do add(name) end
    table.sort(out)
    return out
end

---Read the definition named `adapter` and put it in `ndap.adapters`, or hand
---back the one already there. A name no definition file answers to is nil and no
---error: `available_adapters()` says which names there are, and a name left out
---of `enabled_adapters` is nil the same way; a file that fails to load is nil and
---why, and is re-read on the next call rather than remembered broken.
---Needs no `setup()`, for the reason `available_adapters` gives.
---@param adapter string
---@return ndap.AdapterDef? def, string? err
function M.load_adapter(adapter)
    if not _enabled(adapter) then return nil end

    local loaded = M.adapters
    if loaded[adapter] then return loaded[adapter] end

    local path = _definitions()[adapter]
    if not path then return nil end

    local chunk, load_err = loadfile(path)
    if not chunk then return nil, load_err end
    local ok, def = pcall(chunk)
    if not ok then return nil, def end
    if type(def) ~= "table" then
        return nil, ("%s: expected a table, got %s"):format(path, type(def))
    end

    loaded[adapter] = def
    return def
end

---One of an adapter's named `modes` (`ndap.Mode`), or nil. A projection like
---`available_adapters`: it needs no `setup()` and brings nothing up.
---@param adapter string
---@param name string
---@return ndap.Mode?
function M.mode(adapter, name)
    return require("ndap.run.schema").mode(adapter, name)
end

---An adapter's mode names, sorted. Needs no `setup()`, like `available_adapters`.
---@param adapter string
---@return string[]
function M.mode_names(adapter)
    return require("ndap.run.schema").mode_names(adapter)
end

---The inputs a mode declares (`name -> ndap.Input`), or an empty table. Hand an
---entry to `ndap.run.inputs` to read, describe, seed or complete it. Needs no
---`setup()`, like `available_adapters`.
---@param adapter string
---@param mode_name string
---@return table<string, ndap.Input>
function M.mode_inputs(adapter, mode_name)
    return require("ndap.run.schema").mode_inputs(adapter, mode_name)
end

---The input names a mode marks `required = true`, sorted: the ones a run fails
---without. Needs no `setup()`, like `available_adapters`.
---@param adapter string
---@param mode_name string
---@return string[]
function M.mode_required(adapter, mode_name)
    return require("ndap.run.schema").mode_required(adapter, mode_name)
end

---A starting value for one declared input, appropriate to the form it is
---authored in (the form `:Ndap new_run_file` writes). Deep-copied, so a caller
---may keep or mutate it. Needs no `setup()`, like `available_adapters`.
---@param input ndap.Input?
---@return any
function M.input_seed(input)
    return require("ndap.run.inputs").seed(input)
end

---Load an adapter's definition, check it, and show what it accepts: anything
---wrong with the definition or its tooling, then its modes and the inputs each
---declares. With no adapter, lists every registered name without loading one.
---The entry point behind `:Ndap adapter_info`.
---@param adapter? string  adapter name, e.g. "debugpy"
---@param mode? string  a single mode to show, e.g. "script"
function M.adapter_info(adapter, mode)
    _require_setup("adapter_info")
    return require("ndap.adapter_info").show(adapter, mode)
end

---Launch or attach under an adapter using one of its declared `modes`, assembling
---the request body from `parameters`: the answers to the mode's declared inputs,
---each in its typed form (a number, a boolean, a table; text is the command
---line's form, parsed before `start_mode` sees it). The entry point behind
---`:Ndap start`.
---
---Pass a `presenter` to show the run in a UI of your own: the run's buffers,
---progress and outcome go to those callbacks, ndap's own panel never sees it, and
---the run is yours to `remove_run` when you are done with it.
---@param adapter string  adapter name, e.g. "debugpy"
---@param mode string  mode name, e.g. "binary"
---@param parameters? table<string, any>  input name -> value, e.g. { program = "./main.py" }
---@param presenter? ndap.runner.Presenter  a caller showing the run itself
---@return ndap.runner.Run?
function M.start_mode(adapter, mode, parameters, presenter)
    _require_setup("start_mode")
    -- Cleaning is ndap tidying its own runs before adding another; a run shown
    -- elsewhere is not one of them, and its presenter decides when to drop it.
    if not presenter then M.clean() end
    return require("ndap.run.runner").start_mode(adapter, mode, parameters, presenter)
end

---Forget a run: its presenter is told to dispose of what it made (ndap's own
---wipes the run's buffers; a caller's does whatever it does), and the finished
---rows of the sessions it produced are dropped from the debug view. Cancel a live
---run before removing it. The view is only cleaned when it exists; disposing of a
---run is no reason to build one.
---@param run ndap.runner.Run
function M.remove_run(run)
    _require_setup("remove_run")
    require("ndap.run.runner").remove(run)
    local view = require("ndap.commands").view.debug_view_if_open()
    if view then view:clear_sessions(run.sessions) end
end

---Start a new run with the most recent task's configuration. Warns when nothing
---has run yet.
function M.rerun()
    _require_setup("rerun")
    M.clean()
    require("ndap.run.runner").rerun()
end

---Drop every finished run, wiping its buffers, and the rows of the sessions
---they produced, leaving live runs and sessions untouched. The debug view is
---only cleaned when it exists; cleaning is no reason to create one.
function M.clean()
    _require_setup("clean")
    require("ndap.run.runner").clean()
    local view = require("ndap.commands").view.debug_view_if_open()
    if view then view:clear_finished_sessions() end
end

---Report whether the cwd is inside a project and, if so, the resolved root and
---data file (and whether that file exists on disk yet). Echoed to the command
---line rather than notified, so it reads as a status query.
function M.project_info()
    _require_setup("project_info")
    local store = require("ndap.store")
    local root  = store.root()
    if not root then
        vim.api.nvim_echo({
            { "[ndap] ",                          "Title" },
            { "not in a project (no root marker)", "WarningMsg" },
        }, false, {})
        return
    end
    local chunks = {
        { "[ndap] project: ", "Title" },
        { root,                "Directory" },
    }
    vim.api.nvim_echo(chunks, false, {})
end

---Register a user command under `name` that forwards its arguments, its range
---and its completion to the dispatcher: `:Ndap` itself, and the aliases
---`create_cmd_alias` makes. A name someone else holds is never taken silently:
---it is left alone, and the caller says so.
---@param name string
---@param desc string
---@return boolean created  false when `name` was already taken
local function _register_command(name, desc)
    if vim.api.nvim_get_commands({})[name] then return false end
    vim.api.nvim_create_user_command(name, function(opts)
        -- Report an error as a notification rather than a stack trace. nargs="*"
        -- always yields fargs; the fallback only satisfies its optional type.
        local ok, err = pcall(function()
            -- This is the demand that brings the plugin up, before any subcommand
            -- (including the ones that only touch the UI) runs.
            _require_setup("command")
            require("ndap.usercmd").run(opts.name, opts.fargs or {}, opts)
        end)
        if not ok then
            vim.notify("[ndap] " .. opts.name .. " command error\n" .. tostring(err),
                vim.log.levels.ERROR)
        end
    end, {
        nargs = "*",
        range = true,
        desc = desc,
        complete = function(arg_lead, cmd_line)
            return require("ndap.usercmd").complete(arg_lead, cmd_line)
        end,
    })
    return true
end

---Install the project-state autocmds. Each is a no-op while cold.
local function _create_autocmds()
    local group = vim.api.nvim_create_augroup("ndap", { clear = true })

    -- Persist before leaving the current project (cwd change) and on exit.
    vim.api.nvim_create_autocmd({ "DirChangedPre", "VimLeavePre" }, {
        group    = group,
        callback = function() M.save_state() end,
        desc     = "ndap: persist breakpoints and expressions",
    })

    -- Gracefully stop active sessions on exit: an adapter killed without a
    -- completed `disconnect` orphans its debuggee, and nvim SIGKILLs adapter
    -- jobs as it exits.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group    = group,
        callback = function() M.shutdown() end,
        desc     = "ndap: disconnect sessions so debuggees are terminated on exit",
    })

    -- After a cwd change, re-resolve the project root and restore its state
    -- (or clear it, when the new cwd is not inside a project).
    vim.api.nvim_create_autocmd("DirChanged", {
        group    = group,
        callback = function() M.reload_state() end,
        desc     = "ndap: restore project state after cwd change",
    })
end

---Whether `setup()` has run: the config is applied and the command and the
---autocmds are in place. `:checkhealth ndap` reports on the strength of it.
---@return boolean
function M.is_setup()
    return _setup_done
end

---The configuration as it shipped, before `setup()` merged the user's options
---over it. A fresh deep copy every call, so the caller may keep or mutate it;
---`:checkhealth ndap` diffs the live config against it.
---@return ndap.Config
function M.get_default_config()
    return require("ndap.config").defaults()
end

---Register a user command `name` that forwards its arguments, its range and its
---completion to `:Ndap`, so `:'<,'>Debug inspect` still reads the selection and
---a value that escaped its own space (`--command ./main.py\ --verbose`) reaches
---the run parser intact. A name already taken is left alone with a warning.
---@param name string  a user command name: an uppercase letter, then word characters
---@return boolean created  false when `name` was already taken
function M.create_cmd_alias(name)
    _require_setup("create_cmd_alias")
    if type(name) ~= "string" or not name:match("^%u") then
        error("[ndap] create_cmd_alias() needs a user command name: "
            .. "an uppercase letter, then word characters", 2)
    end
    if name == COMMAND then
        vim.notify(("[ndap] :%s is the command itself, so no alias was created"):format(name),
            vim.log.levels.WARN)
        return false
    end
    if not _register_command(name, ("ndap commands (alias for :%s)"):format(COMMAND)) then
        vim.notify(("[ndap] :%s is already taken, so no alias was created"):format(name),
            vim.log.levels.WARN)
        return false
    end
    return true
end

---Initialise the plugin. Nothing exists before this runs, so `root_markers`
---and `data_filename` are in place before anything reads them.
---
---Only the config, the command and the autocmds are installed here; the plugin
---proper waits for demand, or for a project with saved breakpoints to restore.
---A second call is refused rather than half-applied.
---@param opts? ndap.Config
function M.setup(opts)
    if _setup_done then
        vim.notify("[ndap] setup() already called; ignoring this call", vim.log.levels.ERROR)
        return
    end

    if vim.fn.has("nvim-0.10") ~= 1 then
        error("[ndap] ndap.nvim requires Neovim >= 0.10")
    end

    require("ndap.config").apply(opts)

    -- Set first: the wiring below reaches guarded entry points (a session added
    -- during `_init` opens the debug view).
    _setup_done = true
    if not _register_command(COMMAND, "ndap commands") then
        vim.notify(("[ndap] :%s is already taken, so it was left alone"):format(COMMAND),
            vim.log.levels.WARN)
    end
    _create_autocmds()

    -- Everything past this point is deferred to the first `:Ndap` or API call,
    -- except when the project has saved breakpoints, which have to show up as
    -- signs without being asked for.
    if _has_saved_state() then _ensure_loaded() end
end

return M
