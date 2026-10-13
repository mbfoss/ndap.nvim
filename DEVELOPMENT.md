# Development

Internals and contributor notes for ndap.nvim. For user-facing usage, see the
[README](README.md).

## Overview

ndap is a Neovim DAP client speaking the Debug Adapter Protocol directly, with no
`nvim-dap` dependency. It manages adapter processes, tracks debug
sessions/breakpoints, and renders a tree-based debug UI. Requires Neovim >= 0.10
(guarded in `setup()`).

`require("ndap").setup(opts)` is the one entry point and is **mandatory**: nothing
exists before it runs. It merges `opts` into
[config.lua](lua/ndap/config.lua), registers the user command, installs the
project-state autocmds, and stops. There is no `plugin/` script, so ndap costs
nothing until a config asks for it. `setup()` being the only door is why
`root_markers` and `data_filename` are settled before the saved-state lookup,
which runs inline rather than deferred, asks
[project.lua](lua/ndap/project.lua), and decodes nothing unless a file exists.

Everything past that is lazy. `_ensure_loaded()` brings up the plugin proper (UI
wiring, DAP subscriptions, restored state) once — on the first `:Ndap` or API
call, or when a state file is found at `setup()` or after a cwd change. Every
public entry point calls `_require_setup()`, which raises the "call setup()
first" error and *is* that demand, so each body can assume a loaded plugin. The
exceptions are the projections (`available_adapters`, `load_adapter`, `mode`,
`mode_names`, `mode_inputs`, `mode_required`, `input_seed`), which read the
runtimepath and the config, bring nothing up, and so answer before any `setup()`.
The autocmds are guarded the same way: cold means nothing to persist and no
session to disconnect.

The command name is hardcoded, so every message and doc line names `:Ndap`, and a
name someone else holds is never taken silently — `:Ndap` is left alone with a
warning. The API and the saved state do not go through the command. A second
`setup()` call is refused, not merged.

## Architecture

The code is layered; **higher layers depend on lower ones, never the reverse**.
Layers communicate through `Signal`s (pub/sub), not back-references: lower layers
emit, higher layers subscribe. `manager` is the single dependency surface for the
UI and commands; prefer it over importing `dap/client` or `dap/breakpoints`.

**Public API**: [lua/ndap/init.lua](lua/ndap/init.lua) `setup`; the run entry
points (`run_mode`, `run_file`, `new_run_file`, `run_again`, `remove_run`); the view
entry points (`open_debug_view`, `close_debug_view`, `toggle_debug_view`,
`open_disassembly_view`); and the projections above. Registers the user command
and hands each invocation to `usercmd`.

**`:Ndap` command line**: [lua/ndap/usercmd.lua](lua/ndap/usercmd.lua) Parses a
typed invocation, routes it to the `commands` tables (or to init's public API for
run/project operations), and completes its arguments. Required lazily, so it —
and `commands` behind it — load on first use. Arguments arrive already split by
Neovim's `<f-args>` rules (`opts.fargs` to run, `nvim_parse_cmd` to complete).

**Active session / programmatic API**:
[lua/ndap/manager.lua](lua/ndap/manager.lua) Owns "which session is active",
which keymaps and UI subscribe to. Wraps the session-id-explicit `dap/client`,
taking operation details as arguments (`continue`/`next`/`step_*`, selection,
`evaluate`, `goto_targets`/`restart_frame`/…, a `capable` predicate). Performs
**no** user interaction: no prompts, pickers or notifications. Re-exports the
client signals and `manager.breakpoints`, so consumers depend only on `manager`.

**Commands**: [lua/ndap/commands.lua](lua/ndap/commands.lua) The user-facing
tables `M.debug.*`, `M.breakpoint.*`, `M.view.*`, reached through `:Ndap …`. Owns
all user interaction (pickers, prompts, notifications, cursor reads) and resolves
it into the details it hands to `manager`, its only path to the DAP layer.
`M.view` also owns the DebugView/DisassemblyView singletons, so this surface
never requires `init`. A peer to `ui/`.

**DAP core**: [lua/ndap/dap/](lua/ndap/dap/)
- `client.lua`: session registry & lifecycle; spawning and session-level events.
- `session.lua`: one DAP session. Owns a Connection, holds all runtime state
  (threads, frames, scopes, variables, modules, sources), drives the protocol
  handshake, and emits events via `session:on(event, fn)`.
- `connection.lua`: a single adapter connection (stdio pipe or TCP socket);
  Content-Length framing, request/response correlation, event dispatch.
- `transport.lua`: streaming Content-Length parser.
- `breakpoints.lua`: global, session-independent breakpoint registry (source,
  function, exception-filter, exception-name breakpoints).
- `proto.lua`: a `---@meta` file of DAP spec types; never `require()` it.

**Types**: [lua/ndap/meta.lua](lua/ndap/meta.lua) is the `---@meta` file of
declaration-only types — the adapter definition (`ndap.AdapterDef`, its modes and
inputs) and `ndap.Module`, the public surface [init.lua](lua/ndap/init.lua)
returns. That file binds `M` to the class, so a field that drifts from it is a
diagnostic. Never `require()` it, like `proto.lua`.

**Adapters & tasks**
- [init.lua](lua/ndap/init.lua) `M.adapters`: the loaded definitions, a plain
  `name → ndap.AdapterDef` table of native DAP process/connection config plus
  optional named `modes`, filled as `ndap.load_adapter` reads them. Users may
  assign into it directly. One file per adapter under `ndap-adapters/` on the
  runtimepath, keyed by filename; the generic `remote` ships as one, and
  `ndap.available_adapters` names them without reading any. The DAP core never
  reads `modes`; only `ndap.run.schema` does.
- [task.lua](lua/ndap/run/task.lua): the task runner backend. Consumes a native
  task (`name`/`adapter`/`request`/`request_args` plus optional `host`/`port`)
  and sends `request_args` as the DAP request body verbatim. `parameters`, the
  mode's answered inputs, reach a `setup` that needs them.
- [runner.lua](lua/ndap/run/runner.lua): the run tracker behind `:Ndap
  run`/`run_file`/`run_again`/`clean`, and the single path from a mode to a running
  session: it resolves the mode, tracks every run, and cancels it. Every run gets
  a `runner.Presenter` taking its buffers, progress and outcome; nothing here
  knows about windows.
- [run_display.lua](lua/ndap/ui/run_display.lua): the presenter ndap's own runs
  get. `for_panel` closes it over one `ui.Panel`
  ([Panel.lua](lua/ndap/ui/Panel.lua)); `setup` installs the result on the
  runner. It makes the run's log buffer, holds the buffers the run spawned so
  `clean` can wipe them, and forwards all of it to that panel. A caller passing
  its own `runner.Presenter` (as tomltasks' `debug` task type does) replaces this
  module for that run: ndap's own panel never sees it, `clean` does not touch it,
  and it leaves ndap through `remove_run`.
- [inputs.lua](lua/ndap/run/inputs.lua): the input registry. `M.types` holds one
  row per scalar type, stating every way it is read (parsed from a command line,
  seeded into a scaffolded document, completed), and `M.sources`, the completion
  an input may ask for by name. Nothing else switches on a type name, so adding
  one is a single row.
- [schema.lua](lua/ndap/run/schema.lua): the engine behind `:Ndap run`, the
  reader for `new_run_file`, and the mode engine `runner` resolves every run
  through. `resolve_task` reads a mode's declared `inputs` from a table of
  parameters and calls its `build`, delivering a complete `ndap.Task` to a `done`
  callback; a `build` may stop to ask the user something first, and the returned
  `cancel` drops the answer if the caller has given up. Only `runner` resolves:
  every front end names a mode and lets the run do the rest.
- [scaffold.lua](lua/ndap/run/scaffold.lua): backs `:Ndap new_run_file`, writing a
  runnable Lua run file naming the `adapter` and `mode` and listing that mode's
  declared inputs under `parameters`, each seeded via `ndap.run.inputs` and
  commented with its `description`, then opens it.

**Persistence**: [store.lua](lua/ndap/store.lua) A thin path and read/write
helper. The project root is the nearest ancestor of the cwd holding a
`root_markers` entry; all project state lives in one JSON file there. The store
knows nothing about *what* is stored: the lifecycle (autocmds, path conversion at
the persistence seam) lives in [init.lua](lua/ndap/init.lua).

**UI**: [lua/ndap/ui/](lua/ndap/ui/) `DebugView.lua` (the main tree view, built
on `TreeBuffer`), plus `DisassemblyView`, `InspectView`, `ReplBuffer`,
`OutputBuffer`, the run display (`run_display`) and its panel (`Panel`), shared
presentation (`format`, `value_hover`, `node_details`) and the sign/inline-value
modules (`breakpoints_ui`, `debugline_ui`, `inlinevars`, `expressions`).

**Toolkit**: [lua/ndap/util/](lua/ndap/util/) Standalone primitives with no ndap
dependencies: `Signal` (the pub/sub primitive), `Tree`/`TreeBuffer`,
`fileextmarks`, `inputwin`, `floatwin`, `fixedwin`, `term`, `throttle`, `timer`,
`fsutil`, `strutil`, `ui`, plus `UndoStack`, `select`, `table` and friends.

## The adapter definition format

An `AdapterDef` describes how to launch a DAP adapter (`command`/`host`/`port`,
optional `setup`/`teardown`, default `request`). Its optional `modes` is a
`table<string, ndap.Mode>`: named launch/attach templates (`binary`, `attach`,
`remote`, …) consumed only by `ndap.run.schema`. Each mode is wholly
self-describing; adapters carry no schema of their own.

| Field         | Meaning                                                                         |
| ------------- | ------------------------------------------------------------------------------- |
| `request`     | `"launch"` or `"attach"`                                                        |
| `inputs`      | what the mode accepts: `name -> ndap.Input`; see below             |
| `build`       | `fun(parameters): table?, table\|string?`, returning the native request body, plus any task-level TCP endpoint; or `nil, err` to abort |

| Field      | Meaning                                                                        |
| ---------- | ------------------------------------------------------------------------------ |
| `type`     | what the input *is*, meaning what `build` receives: `string`/`boolean`/`integer`/`number`, or a collection — `list` (a table of entries, JSON's `array`) or `map` (a table of string keys to values, JSON's `object`). Defaults to `string` |
| `item_type` | a collection's *entry* type, declared as `type` is but scalars only: `{ type = "list", item_type = "integer" }`. Defaults to `string` |
| `completion` | what the value completes with: a named source (`"file"`, `"dir"`); the values themselves (`{ "console", "terminal" }`); or a `fun(partial): string[]`. A written-out set also reaches the scaffolded file as a comment. Completion only *suggests*; nothing rejects a value written past it. On a collection it describes one entry |
| `required` | when `true`, the user must supply the value; leaving it unset is a resolve error. Any other unset input arrives at `build` as nil, which `build` may answer by omitting the field or some other way: an attach `build` asks the user to pick a process for an unset `pid`, which is why no adapter marks that input `required` |
| `description` | a few words on what the input means, e.g. `"process id to attach to"` |

Every type is one row in [inputs.lua](lua/ndap/run/inputs.lua) stating how a value
of it is parsed, described as JSON Schema, seeded and completed, and every named
completion source one entry beside them, so adding either is a single row, never
an `if type == …` anywhere else.

What a value additionally *is* (a path, a port) is not a row: `build` says it,
with `shared.normalize_path` and `shared.resolve_port`. `normalize_path` is strict
— nil in and nil out, anything else raising — and the run reports a wrong type as
the mode's abort rather than put an empty path in the body. A row states what a
value **is**; narrowing one kind of string into another was a second vocabulary
layered on that one, paid for in every projection (a schema merge, a refine step,
a check step, and the rule reconciling a `type` with a `format` naming a different
one), and it bought two behaviours a `build` line each expresses.

#### A string form, and the typed form

- the **string form**, the command line's: `:Ndap run codelldb launch --command
  ./a.out arg1 --cwd /src`. A collection instead takes one token per entry
  (`--env A=1 B=2`), which the parser turns into a table.
- the **typed form**, a run file's or an API caller's: a Lua value that already
  has its type — `env = { A = "1" }`, `port = 8080`, `enabled = true`.

Only `:Ndap run` parses, reading each token against the input's `type` before
resolving. A run file or API caller writes Lua already, so its value must *be* the
value: `port = "8080"` is refused. A collection has no string form; it is always
the table. Both routes land on the declared `type`, so `build` never sees the
difference.

A row therefore states more than a parse. `map` is the clearest case: `--env A=1
B=2` and `{ A = "1" }` both reach `build` as one table. The
[inputs.lua](lua/ndap/run/inputs.lua) row states how a value is read from text and
as a typed value, and how the input is seeded into a scaffolded document and
completed. Adding a type means adding one row, which every consumer — ndap and
easytasks alike — reads.

Both forms must describe the *same* value. A transformation into a different shape
is not a second spelling and does not belong in a row: a launch `build` reads its
`command` input as an argv list and takes `program`/`args` from it directly, and
no token is expanded, so `~`, `$VAR`, `%`, `#` and globs reach the body as
written.

### One description, two entry points

`inputs` is the only description of a mode, and both commands resolve through it:

```
:Ndap run     values     ─→ build ─→ body ─→ task
run_file       parameters ─→ build ─→ body ─→ task
new_run_file   inputs ─→ seeded parameters ─→ (you edit it) ─→ run_file
```

A scaffolded run file names the `adapter` and `mode` and lists that mode's
declared inputs under `parameters`, each seeded by its row and commented with its
`description`. It and `:Ndap run` cannot drift.

- **`build(parameters)`** returns the request body, and optionally a second table
  naming a task-level TCP endpoint. `parameters` arrives read into each declared
  `type`, whichever form the caller wrote. Identity fields the adapter pins
  (`type`/`name`) and fixed defaults go in the body as literals. An unset input is
  nil, and Lua drops nil-valued keys, so `cwd = parameters.cwd` omits `cwd`: write
  the field unconditionally. Guard only a field *derived* from an input
  (`targetCreateCommands = parameters.program and { "target create " ..
  parameters.program }`), since indexing nil throws. The second return value is
  for an adapter whose connection an input configures — the host/port to dial, how
  the shipped `remote` connects; return none and the def's own host/port stay in
  force. A run with neither a command nor a port is refused before it starts,
  naming the adapter and mode.

  Omitting the field is only the *default* answer to an unset input; `build`
  decides otherwise, knowing what the request means. An attach body is nothing
  without a process, so every attach `build` resolves an unset `pid` by asking:

  ```lua
  build = function(parameters)
      local pid, err = shared.resolve_pid(parameters.pid)
      if not pid then return nil, err end   -- cancelled: abort the run
      return { processId = pid }
  end,
  ```

  The schema layer stays out of this: to it a pid is the integer it is. A `build`
  that prompts yields, which is why `resolve_task` calls `build` on a coroutine
  and reports through `done(task, err)` rather than a return — the pid arrives
  from a `vim.ui.select` callback long after a return would have been read. `done`
  fires synchronously for a `build` that asks nothing. Returning `nil` and a
  message aborts, so always resume or the caller waiting on you never hears back.

An input's `description` becomes that field's comment in the scaffolded file:
write it for someone reading the generated run file, not just the command line.
Scaffold a mode after editing it (`:Ndap new_run_file <adapter> <mode>
/tmp/x.lua`) to see what it reads like.

Input *names* are `snake_case` (`stop_on_entry`, `wait_for`): ndap's own
user-facing vocabulary (the `--name` flags at `:Ndap run`), not the adapter's. The
`params` keys keep whatever casing the adapter's wire protocol uses, so
`params.stopOnEntry = parameters.stop_on_entry` is correct.

Which names a mode takes is up to it; there is no portable role vocabulary across
adapters. By convention a `launch` mode takes one `command` input of `type =
"list"`, completing each entry as `"file"`, carrying the program and its
arguments as separate entries, and `build` takes `program = argv[1]` and `args =
{ unpack(argv, 2) }`. No entry is expanded, since they are arguments rather than
paths to resolve (`./...` is a Go package pattern, not a directory). The shipped
`remote` (under `ndap-adapters/`) is the connect-only shape; the definitions in
[ndap-adapters.nvim](https://github.com/mbfoss/ndap-adapters.nvim) are worked
examples of the rest.

## Conventions

- **Lua annotations**: add `---@param`, `---@return`, `---@class`, etc. wherever
  possible.
- **Module naming**: class-based modules are PascalCase; functional modules are
  snake_case.
- **Module-scope `local`s** are prefixed with `_`, except: a name bound directly
  from `require()`, the conventional `M` module table, and class type names.
- **Class privates** are prefixed with `_`. **Function-local** variable names
  are **not** prefixed with `_`.

## Testing & health

```vim
:checkhealth ndap
```

verifies the Neovim version, whether the plugin is initialised, the resolved
project state, and which adapters are registered, by name, since it loads no
definition. `:Ndap adapter_info <adapter>` loads one and reports what is wrong
with it (`schema.validate` plus its tooling); `schema.validate_all()` does the
same for every registered definition at once — the quickest smoke test that a
local change hasn't broken adapter resolution.
