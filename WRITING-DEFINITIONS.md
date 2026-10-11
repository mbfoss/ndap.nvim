# Writing an adapter definition

An adapter definition is one Lua file under an `ndap-adapters/` directory on the
runtimepath, beside `lsp/` and `plugin/` rather than under `lua/`. It states how
to reach a debug adapter (the program that speaks DAP, such as `codelldb` or
`gdb --interpreter=dap`) and what that adapter can be asked to do. The filename
names the adapter: `myadapter.lua` registers as `myadapter`, the name `:Ndap run`
takes.

DAP's three names, kept distinct:

- **debug adapter**: the program ndap spawns or dials, the one speaking DAP
  (`codelldb`, `lldb-dap`, `dlv dap`).
- **debugger**: what that adapter drives. `codelldb` drives LLDB; `gdb` and `dlv`
  speak DAP directly.
- **debuggee**: the program being debugged.

"Adapter" alone always means the first.

Each file returns one `ndap.AdapterDef`:

```lua
return {
    command  = { "gdb", "--interpreter=dap" }, -- how to spawn the adapter; or host/port to connect
    setup    = function(config, ctx, callback) end, -- optional, see below
    modes    = {
        binary = {
            description = "debug a native executable",
            request     = "launch", -- or "attach"
            inputs      = {
                command = { type = "string", completion = "command", required = true, description = "command line to debug" },
            },
            build       = function(parameters) -- parameters -> DAP body
                local program, args = require("ndap.shared").split_command(parameters.command)
                return { program = program, args = args }
            end,
        },
    },
}
```

A definition is read the first time that adapter is reached for by name
(`ndap.load_adapter`, a run, `:Ndap adapter_info <adapter>`), never at startup.
Listing adapters (`ndap.available_adapters`, `:checkhealth`) reads filenames
only. Keep top-level work to building the table; anything expensive belongs in
`setup`, which runs per run. The file is read with `loadfile`, not `require`, so
nothing can `require` it and it can require no sibling. Helpers come from
`ndap.shared`.

## `ndap.AdapterDef`

Every field is optional. What is set decides how the adapter is reached and what
it can run.

| Field | Type | Meaning |
| --- | --- | --- |
| `command` | `string` \| `string[]` | Adapter process to spawn, spoken to over stdio. A string is split on shell whitespace (`"python3 -m debugpy"`); a list is used verbatim. A missing executable is reported before the session starts. Wins over `host`/`port`: with both set, this spawns and those are ignored. |
| `host` | `string` | Host of an already-running adapter, used only when there is no `command`. Defaults to `127.0.0.1`. No shipped definition sets it; a mode's `build` or a `setup` supplies the connection. |
| `port` | `integer` | Port to connect to, used only when there is no `command`; ndap dials `host:port`, retrying for about 3s. A port set for the run by `setup` or a mode's `build` also selects TCP over `command`, which is how the shipped `remote` connects. A run with neither a command nor a port is refused before it starts. |
| `cwd` | `string` | Working directory for the spawned adapter. Defaults to Neovim's cwd. |
| `env` | `table<string,string>` | The adapter's own environment, not the debuggee's, merged over Neovim's. Set only what the adapter needs, such as a search path. |
| `type` | `string` | DAP `adapterID` override. Defaults to the filename stem. |
| `defer_launch_attach` | `boolean` | Send `launch`/`attach` after `configurationDone` rather than after `initialize`, for adapters that require that order. |
| `modes` | `table<string, ndap.Mode>` | The named modes, keyed by the name `:Ndap run <adapter> <mode>` takes. |
| `setup` | `fun(config, ctx, callback)` | Runs before the session; see below. |
| `teardown` | `fun(config, state)` | Runs after the session, with whatever `setup` passed as `state`; also when `setup` fails. |

An `ndap.Mode` is one runnable configuration:

| Field | Type | Meaning |
| --- | --- | --- |
| `description` | `string` | A line shown in pickers and `:Ndap new_run_file` output. |
| `request` | `"launch"` \| `"attach"` | Which DAP request the mode issues. |
| `inputs` | `table<string, ndap.Input>` | What the user is asked for, keyed by the name used as `--name`. |
| `build` | `fun(parameters): table?, table\|string?` | Turns inputs into the request body. A second return value is a `host`/`port` table the run should dial; `nil, "message"` aborts. Runs in a coroutine and may yield, so a `vim.ui.select` picker inside it is fine. |

An `ndap.Input` describes one value:

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | `"string"` \| `"boolean"` \| `"integer"` \| `"number"` \| `"list"` \| `"map"` | Defaults to `string`. `list` is a table of entries, `map` a table of string keys to values: JSON's `array` and `object` under DAP's names. |
| `item_type` | as above, scalars only | The entry type of a `list` or `map`. Defaults to `string`. |
| `required` | `boolean` | Leaving it unset is an error. Defaults to `false`. |
| `completion` | `"file"` \| `"dir"` \| `"command"` \| `string[]` \| `fun(partial): string[]` | What the value completes with. Suggests only; never rejects a value. |
| `description` | `string` | A few words on what the input means, shown by `:Ndap new_run_file` and command-line completion. |

## Modes

A definition without `modes` cannot be run: nothing completes and nothing can be
generated, since a raw DAP body describes nothing about itself (see
[Why inputs](README.md#why-inputs-and-not-raw-dap)). A mode declares the `inputs`
it accepts and a `build` that turns `parameters` into the native body:

```lua
return {
    command  = { "my-dap-adapter", "--stdio" },
    modes    = {
        binary = {
            description = "debug an executable",
            request     = "launch",
            inputs      = {
                command       = { type = "string",  completion = "command", required = true, description = "command line to debug" },
                cwd           = { type = "string",  completion = "dir",     description = "working directory" },
                env           = { type = "map",                             description = "environment variables" },
                stop_on_entry = { type = "boolean",                         description = "break at program entry" },
            },
            build = function(parameters)
                local shared = require("ndap.shared")
                local program, args = shared.split_command(parameters.command)
                return {
                    program     = program,
                    args        = args,
                    cwd         = shared.normalize_path(parameters.cwd),
                    env         = parameters.env,
                    stopOnEntry = parameters.stop_on_entry,
                }
            end,
        },
    },
}
```

No further wiring is needed:

```vim
:Ndap run myadapter binary --command ./a.out --cwd /src --stop_on_entry true
:Ndap new_run_file myadapter binary
```

- **`inputs`**: one entry per accepted value, keyed by the name typed at
  `:Ndap run` or written under a run file's `parameters`. `type` is what `build`
  receives and all an input declares about its value. A collection (`list`, or
  `map` with string keys) declares its entry type under `item_type`:
  `{ type = "list", item_type = "integer" }`; without one, entries are strings.
  A `map` entry is written `key=value`. A directional map is described the same
  way, with the key naming the translated side: `local=remote` where the local
  path becomes the remote one, `remote=local` the other way round. The adapter's
  documentation decides which; the two shipped in
  [ndap-adapters.nvim](https://github.com/mbfoss/ndap-adapters.nvim) differ
  because the adapters do. Every type is one row in
  [inputs.lua](lua/ndap/run/inputs.lua), which every consumer reads.
- **`completion`**: a named source (`"file"`, `"dir"`, `"command"`, the last
  completing each token of a command line as a path); the values themselves
  (`{ "console", "terminal" }`); or `fun(partial): string[]` when they can only
  be computed. On a `list` or `map` it describes one entry. Only a written-out
  set reaches the scaffolded file, as a comment. A boolean completes as
  `true`/`false`.
- **Paths and ports**: a path input is a `string` and a port an `integer`;
  `build` supplies whatever else either needs to be.
  `shared.normalize_path(parameters.cwd)` resolves `~` and `$VAR` (nil in, nil
  out), `shared.normalize_paths` does the same for a `list`, entry by entry, and
  `shared.resolve_port(parameters.port)` holds a port to its range, returning the
  `nil, err` pair an abort already returns. `normalize_path` is strict: anything
  but a string or nil (such as a whole `map` where one entry belongs) raises, and
  the run reports it as the mode's abort rather than send a body with an empty
  path.
- **`required`**: an unset required input is a resolve error naming the input.
  Otherwise an unset input arrives as `nil`, and Lua drops nil-valued keys, so
  `cwd = parameters.cwd` omits `cwd`. Write the field unconditionally and
  optional fields take care of themselves.
- **`build(parameters)`**: returns the request body: the adapter's own key
  names, plus any identity fields it pins, as literals. `parameters` arrives read
  into each declared `type`, whichever form the caller wrote. A second return
  value is the `host`/`port` the run should dial, for an adapter whose connection
  an input configures; return none and the definition's own `host`/`port` stay in
  force.
- **Aborting**: return `nil` and a message, a string where a successful call
  returns the connection: the ordinary `nil, err` pair.
- **Asking the user**: `build` may yield, which is how an attach mode with no
  `pid` opens a process picker instead of sending a meaningless body: `local pid,
  err = shared.resolve_pid(parameters.pid); if not pid then return nil, err end`.
  Always resume, with a body or an abort.

`:Ndap run`, `:Ndap new_run_file` and mode-based run files all resolve through
this one `parameters` → `build` path, so a mode is described once and the three
cannot drift. The shipped [remote.lua](ndap-adapters/remote.lua) is a compact
reference for a mode returning a connection rather than a body; for a
spawn-then-connect definition, see the example below.

## Setup and teardown

`setup` runs after a mode's `build` and before ndap connects. It starts the
adapter as a server and reports its port, or locates its binary and fails with a
readable message. Errors go through `callback("...")`. State passed as the
second argument, `callback(nil, { handle = h })`, arrives as `teardown`'s second
argument, which is how `teardown` stops what `setup` started; hand the same state
back *with* an error and `teardown` runs on the failure too. `callback(err,
state)` must fire exactly once.

`setup` may edit `config` in place, most usefully `config.host`/`config.port`,
which is how a TCP-server adapter gets started and then connected to. A
connection `build` returned is already in `config`; `setup` runs last and may
overwrite it. Its `ctx` carries:

- `report(msg)`: a progress line.
- `add_bufnr(bufnr, opts?)`: attach a buffer `setup` created to the run, so it
  is listed under the session.
- `make_buf_name(kind)`: name a buffer the way the run's own are
  (`:b ndap://<number>/<name>:<kind>`). A reserved kind (`repl`, `output`,
  `term`, `dap`, `log`) or a name already taken is an error rather than a suffix.
- `mode`: the mode name this run resolved from, for gating one mode rather than
  the whole definition (such as refusing a mode the installed binary is too old
  for). Treat an unrecognized `mode` as "none of mine" and proceed.
- `parameters`: the answered inputs `build` was called with, how a `setup` that
  starts the debuggee learns what to start. A raw task names no mode, and so
  carries none.

```lua
return {
    setup = function(config, ctx, callback)
        local shared = require("ndap.shared")
        local handle, err
        local done = false -- callback must fire exactly once
        handle, err = shared.spawn({ "my-dap", "--listen", "127.0.0.1:0" }, {
            cwd           = config.cwd,
            bufname       = ctx.make_buf_name("server"),
            line_buffered = true,
            on_stdout     = function(_, lines)
                for _, line in ipairs(lines) do
                    local port = not done and line:match("listening on port (%d+)")
                    if port then
                        done = true
                        config.host, config.port = "127.0.0.1", tonumber(port)
                        callback(nil, { handle = handle })
                    end
                end
            end,
            on_exit       = function(code)
                if done then return end
                done = true
                callback(("my-dap exited (code %d) before reporting a port"):format(code))
            end,
        })
        if not handle then return callback("failed to start my-dap: " .. tostring(err)) end
        ctx.add_bufnr(handle.bufnr, { label = "my-dap server" })
        ctx.report("waiting for server port")
    end,
    teardown = function(_, state)
        if state and state.handle then state.handle.stop() end
    end,
}
```

Any adapter that announces its port on startup fits this shape; only the pattern
matched against its output changes. A `setup` that starts the debuggee is the
same shape one step out, reading the command line from `ctx.parameters`.

## Helpers

`ndap.shared` carries `split_command`, `normalize_path`, `normalize_paths`,
`resolve_port`, `free_port`, `resolve_pid`, `spawn`, and
`resolve_path(candidates, accept, opts?)`, which returns the first candidate
`accept` approves and everything tried:

```lua
local shared = require("ndap.shared")
local exe, tried = shared.resolve_path({ "dlv", "$GOBIN/dlv" }, shared.is_executable)
```

Several modes sharing fields declare them once in a group and compose each
mode's `inputs` with `vim.tbl_extend("error", _common_inputs, { ... })`: groups
merge left to right, and a name declared twice raises rather than silently
overriding. The merge is shallow, so a spec is shared with every mode composing
that group; treat one as read-only. `free_port()` returns a currently-unused
port, for an adapter that has to be told one; it errors rather than hand back a
port nobody can bind.

`shared.split_command(command)` splits a `command` input into the
`program`/`args` pair a launch body wants, quotes and backslashes included. It
splits only, passing every token through as written: `~`, `$VAR`, `%`, `#` and
globs are ordinary characters (`./...` stays `./...`), and a list is used
verbatim. Expand a token with `normalize_path` when the field is a path.

An entry is a literal path, never a glob. `$VAR` and `~` expand wherever they
appear, as `vim.fs.normalize` does elsewhere in Neovim; `${VAR}` braces do not. An
entry naming an unset or empty variable is skipped, which is what lets the list
above work with only `$GOBIN` set. A relative entry resolves against `opts.cwd`;
pass no `cwd` for a list of programs, where a bare name is looked up on `$PATH`.

Use `shared.is_directory` for directories, and a custom predicate when *working*
means more than present (such as a minimum version). Directory checks should
test a file inside the directory: a virtualenv's `"$VIRTUAL_ENV/bin/python"`, not
`"$VIRTUAL_ENV"`.

## Templates

The definitions in
[ndap-adapters.nvim](https://github.com/mbfoss/ndap-adapters.nvim) are worked
examples of the common shapes: an adapter over stdio, one located on `PATH` or in
a package directory, and one started as a server and then connected to. Adapt the
closest. The full contract is in the `ndap.AdapterDef` and `ndap.Mode`
annotations in [lua/ndap/meta.lua](lua/ndap/meta.lua).

New definitions are welcome. Follow the structure and comment style of the
existing files, and cite the adapter's documentation the field set is based on at
the top of the file.
