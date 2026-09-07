---@brief The `:Ndap` command line: parse a typed invocation, route it to the
---`commands` tables (or `init`'s public API for the run/project operations), and
---complete its arguments. `init` requires this lazily from the `:Ndap`
---callback, so none of it loads until the command is first used.

local commands = require("ndap.commands")
local ndap    = require("ndap")

local M        = {}

---Warn about an unrecognised subcommand, pointing at the nearest known names.
---`prefix` names the level it was typed at (e.g. "breakpoint"), so the message
---says which list the suggestions come from.
---@param sub string|nil
---@param subs string[]
---@param prefix string?
local function _warn_unknown(sub, subs, prefix)
    local where = prefix and (prefix .. ": ") or ""
    local msg = ("[ndap] %sunknown subcommand '%s'"):format(where, tostring(sub))
    local near = vim.fn.matchfuzzy(subs, tostring(sub))
    if #near > 0 then
        msg = msg .. "; did you mean " .. table.concat({ unpack(near, 1, 3) }, ", ") .. "?"
    else
        msg = msg .. "; :help ndap-commands for the full list"
    end
    vim.notify(msg, vim.log.levels.WARN)
end

local _bp_subs = {
    "toggle", "column", "remove",
    "clear_file", "clear_all", "clear_fn",
    "enable", "disable", "toggle_enabled", "enable_all", "disable_all",
    "condition", "logpoint",
    "fn", "exception_filter", "exception_type",
    "data", "data_clear", "data_list",
    "list",
}

---Run the `breakpoint` subcommand. Also reachable via `:Ndap breakpoint …`.
---@param args string[]
local function _bp_run(args)
    local sub = args[1]
    -- In a disassembly buffer the toggle acts on the instruction under the
    -- cursor, which only the (already-open) view can resolve.
    local disasm = commands.view.disassembly_view_if_open()
    if sub == nil or sub == "" or sub == "toggle" then
        if vim.b.ndap_disasm and disasm then
            disasm:toggle_bp_at_cursor()
        else
            commands.breakpoint.toggle()
        end
    elseif sub == "column" then
        if args[2] then
            vim.notify("[ndap] breakpoint column takes no argument, got '" .. args[2] .. "'",
                vim.log.levels.WARN)
        else
            commands.breakpoint.column()
        end
    elseif sub == "remove" then
        commands.breakpoint.remove()
    elseif sub == "clear_file" then
        commands.breakpoint.clear_file()
    elseif sub == "clear_all" then
        commands.breakpoint.clear_all()
    elseif sub == "clear_fn" then
        commands.breakpoint.clear_fn()
    elseif sub == "enable" then
        commands.breakpoint.enable()
    elseif sub == "disable" then
        commands.breakpoint.disable()
    elseif sub == "toggle_enabled" then
        commands.breakpoint.toggle_enabled()
    elseif sub == "enable_all" then
        commands.breakpoint.enable_all()
    elseif sub == "disable_all" then
        commands.breakpoint.disable_all()
    elseif sub == "condition" then
        commands.breakpoint.condition()
    elseif sub == "logpoint" then
        commands.breakpoint.logpoint()
    elseif sub == "fn" then
        commands.breakpoint.fn(args[2])
    elseif sub == "exception_filter" then
        commands.breakpoint.exception_filter()
    elseif sub == "exception_type" then
        commands.breakpoint.exception_type(args[2], args[3])
    elseif sub == "data" then
        commands.breakpoint.data(args[2])
    elseif sub == "data_clear" then
        commands.breakpoint.data_clear()
    elseif sub == "data_list" then
        commands.breakpoint.data_list()
    elseif sub == "list" then
        commands.breakpoint.list()
    else
        _warn_unknown(sub, _bp_subs, "breakpoint")
    end
end

---Completion for the `breakpoint` subcommand.
---@param rest string[]
---@return string[]
local function _bp_complete(rest)
    if #rest == 0 then return _bp_subs end
    if rest[1] == "fn" and #rest == 1 then
        return vim.tbl_map(function(bp) return bp.name end,
            require("ndap.dap.breakpoints").function_breakpoints())
    end
    if rest[1] == "exception_type" and #rest == 1 then
        return vim.tbl_map(function(bp) return bp.name end,
            require("ndap.dap.breakpoints").exception_name_breakpoints())
    end
    if rest[1] == "exception_type" and #rest == 2 then
        return { "always", "unhandled", "userUnhandled", "never" }
    end
    return {}
end

local _view_subs = { "toggle", "hide" }

---Run the `view` subcommand: bare `:Ndap view` opens (or focuses) the debug
---view, so it never closes a view the user asked for; `toggle` and `hide` are
---the explicit ways to close it.
---@param args string[]
local function _view_cmd(args)
    local sub = args[1]
    if sub == nil or sub == "" then
        commands.view.open()
    elseif sub == "toggle" then
        commands.view.toggle()
    elseif sub == "hide" then
        commands.view.hide()
    else
        _warn_unknown(sub, _view_subs, "view")
    end
end

local _debug_subs = {
    "start", "rerun", "start_file", "new_run_file", "adapter_info",
    "breakpoint",
    "view", "panel", "continue", "continue_all",
    "step_over", "next", "step_in", "step_out", "step_back",
    "step_in_target", "reverse_continue",
    "jump_to_cursor", "restart_frame", "exception_info",
    "pause", "restart",
    "stop", "stop_all",
    "session", "thread", "terminate_thread", "frame",
    "inspect", "value", "disassemble",
    "project", "clean",
}

---Read one `--name` argument group from the fargs: a scalar takes exactly one
---token, a `list` one entry per token, a `map` one `KEY=VALUE` per token (split
---at the first `=`). No escaping. An empty list or map leaves the input unset; a
---boolean with no token is true; any other scalar needs one. The registry reads
---strings; the `--name`/`KEY=VALUE` syntax typed here is this file's.
---@param spec ndap.Input
---@param group string[]
---@return any? value, string? err
local function _parse_input_group(spec, group)
    local inputs = require("ndap.run.inputs")
    local decl_err = inputs.check(spec)
    if decl_err then return nil, decl_err end

    if spec.type ~= "list" and spec.type ~= "map" then
        -- A bare boolean flag means true, as it does on a command line.
        if #group == 0 then
            if spec.type == "boolean" then return true end
            return nil, "expected a value"
        end
        if #group > 1 then
            return nil, ("expected one value, got %d"):format(#group)
        end
        return inputs.parse(spec, group[1])
    end

    if #group == 0 then return nil end

    local out = {}
    for _, tok in ipairs(group) do
        local key = nil
        if spec.type == "map" then
            local eq = tok:find("=", 1, true)
            if not eq or eq == 1 then
                return nil, ("expected KEY=VALUE, got %q"):format(tok)
            end
            key, tok = tok:sub(1, eq - 1), tok:sub(eq + 1)
        end
        local value, perr = inputs.parse_entry(spec, tok)
        if perr then return nil, perr end
        if key then out[key] = value else out[#out + 1] = value end
    end
    return out
end

---Read `:Ndap start <adapter> <mode> [--input value …] …` from the fargs after
---`start`. The adapter and mode are the first two positionals; each later token of
---the form `--name` must name a declared input, and the tokens up to the next
---one are its values (one for a scalar, none for a boolean, any number for a
---list, a `KEY=VALUE` each for a map). A bare `--` marks the one token after it
---as a value, however that token is spelled, which is the only way to write a
---value that is itself `--`-prefixed. Names are checked against the mode here,
---so a typo is refused
---before the run starts.
---@param tokens string[]  the fargs after `start`
---@return string? adapter, string? mode, table<string, any>? parameters
local function _parse_start_args(tokens)
    local adapter, mode = tokens[1], tokens[2]
    local schema = require("ndap.run.schema")
    local mode_def = adapter and mode and schema.mode(adapter, mode)
    -- No such adapter/mode: leave the flags alone and let start_mode report the
    -- adapter or mode itself, rather than an "unknown input" for every flag.
    if not mode_def then return adapter, mode, {} end
    local declared = mode_def.inputs or {}

    local parameters, seen, i = {}, {}, 3
    while i <= #tokens do
        local flag = tokens[i]
        local name = flag:match("^%-%-(.+)$")
        local spec = name and declared[name]
        if not spec then
            -- `--name=value` is a spelling the command line does not have: a
            -- value is its own argument. The token fits both readings, so the
            -- message names both, the input's and the debuggee's.
            local head = flag:match("^%-%-([^=]+)=")
            if head and declared[head] then
                vim.notify(("[ndap] start: --%s takes its value as its own argument, "
                    .. "--%s <value> (or `-- %s` for the debuggee)"):format(
                    head, head, flag), vim.log.levels.WARN)
                return
            end
            -- Either a mistyped input or a value spelled like one (a debuggee's
            -- own `--verbose`); the hint names the escape for the second reading.
            local hint = ""
            if name then
                hint = (" (for a value, write `-- %s`)"):format(flag)
            end
            vim.notify(("[ndap] start: expected a declared input, got '%s'%s; declared: %s"):format(
                flag, hint, table.concat(schema.mode_input_names(adapter, mode), ", ")),
                vim.log.levels.WARN)
            return
        end
        if seen[name] then
            vim.notify("[ndap] start: --" .. name .. " given more than once", vim.log.levels.WARN)
            return
        end
        seen[name] = true
        local group = {}
        i = i + 1
        while i <= #tokens do
            local tok = tokens[i]
            if tok == "--" then
                -- Marks one token as a value. `-- --` is therefore how a value
                -- that is itself `--` is written, and a trailing `--` marks
                -- nothing, as it does everywhere else.
                i = i + 1
                if tokens[i] == nil then break end
                group[#group + 1] = tokens[i]
                i = i + 1
            elseif tok:match("^%-%-") then
                break
            else
                group[#group + 1] = tok
                i = i + 1
            end
        end
        local value, err = _parse_input_group(spec, group)
        if err then
            vim.notify("[ndap] start: --" .. name .. ": " .. err, vim.log.levels.WARN)
            return
        end
        parameters[name] = value
    end
    return adapter, mode, parameters
end

---Dispatch a `:Ndap …` invocation from its split arguments.
---@param args string[]  arguments after the subcommand
---@param opts table     nvim_create_user_command's opts
local function _debug_run(_, args, opts)
    local sub = args[1]
    -- Bare `:Ndap` opens the debug view: the one thing that is useful at any
    -- point, session or not, and the way in for everything the view offers.
    if sub == nil or sub == "" then
        commands.view.open()
    elseif sub == "start_file" then
        ndap.start_file(args[2])
    elseif sub == "start" then
        local adapter, mode, parameters = _parse_start_args({ unpack(args, 2) })
        if parameters then ndap.start_mode(adapter or "", mode or "", parameters) end
    elseif sub == "new_run_file" then
        ndap.new_run_file({ unpack(args, 2) })
    elseif sub == "adapter_info" then
        ndap.adapter_info(args[2], args[3])
    elseif sub == "rerun" then
        ndap.rerun()
    elseif sub == "view" then
        _view_cmd({ unpack(args, 2) })
    elseif sub == "panel" then
        commands.panel.toggle()
    elseif sub == "continue" then
        commands.debug.continue()
    elseif sub == "continue_all" then
        commands.debug.continue_all()
    elseif sub == "step_over" or sub == "next" then
        commands.debug.step_over()
    elseif sub == "step_in" then
        commands.debug.step_in()
    elseif sub == "step_out" then
        commands.debug.step_out()
    elseif sub == "step_back" then
        commands.debug.step_back()
    elseif sub == "step_in_target" then
        commands.debug.step_in_target()
    elseif sub == "reverse_continue" then
        commands.debug.reverse_continue()
    elseif sub == "jump_to_cursor" then
        commands.debug.jump_to_cursor()
    elseif sub == "restart_frame" then
        commands.debug.restart_frame()
    elseif sub == "exception_info" then
        commands.debug.exception_info()
    elseif sub == "pause" then
        commands.debug.pause()
    elseif sub == "restart" then
        commands.debug.restart()
    elseif sub == "stop" then
        commands.debug.stop()
    elseif sub == "stop_all" then
        commands.debug.stop_all()
    elseif sub == "inspect" then
        -- A `'<,'>` range (e.g. `:'<,'>Debug inspect` from visual mode) sets
        -- opts.range > 0; inspect then reads the `'<`/`'>` marks.
        commands.debug.inspect(args[2], opts.range and opts.range > 0)
    elseif sub == "value" then
        commands.debug.value(args[2], opts.range and opts.range > 0)
    elseif sub == "disassemble" then
        commands.debug.disassemble()
    elseif sub == "session" then
        commands.debug.session()
    elseif sub == "thread" then
        commands.debug.thread()
    elseif sub == "terminate_thread" then
        commands.debug.terminate_thread()
    elseif sub == "frame" then
        commands.debug.frame()
    elseif sub == "project" then
        ndap.project_info()
    elseif sub == "clean" then
        ndap.clean()
    elseif sub == "breakpoint" then
        _bp_run({ unpack(args, 2) })
    else
        _warn_unknown(sub, _debug_subs, nil)
    end
end

---Candidate values for the token being completed under the open input. A `map`
---token is `KEY=VALUE` and only the value completes (a key is free-form): the
---part after the first `=` is what the registry answers for, with the key kept on
---each candidate.
---@param spec ndap.Input
---@param arg_lead string
---@return string[]
local function _complete_input_value(spec, arg_lead)
    local inputs = require("ndap.run.inputs")
    if spec.type ~= "map" then return inputs.completion(spec, arg_lead) end
    local eq = arg_lead:find("=", 1, true)
    if not eq then return {} end
    local head = arg_lead:sub(1, eq)
    return vim.tbl_map(function(v) return head .. v end,
        inputs.completion(spec, arg_lead:sub(eq + 1)))
end

---Completion for `:Ndap start …`: the adapter, then the mode, then each declared
---input as `--name`, and a value once a flag is open (paths, true/false, a fixed
---set). `--` starts a flag, so a value position is only completed off a `--`
---name or a bare `--` marker, which is what marks the next token as a value.
---@param schema table
---@param toks string[]     the fargs after `start`, up to the token being completed
---@param arg_lead string   the token being completed
---@return string[]
local function _start_complete(schema, toks, arg_lead)
    local adapter, mode_name = toks[1], toks[2]
    if not adapter then return ndap.available_adapters() end
    if not mode_name then return schema.mode_names(adapter) end

    -- The last `--name` is the open input; count the values it has taken since.
    -- A bare `--` makes the token after it a value, spelled however it is.
    local declared = schema.mode_inputs(adapter, mode_name)
    local open, taken, supplied, raw = nil, 0, {}, false
    for i = 3, #toks do
        local tok = toks[i]
        if raw then
            raw, taken = false, taken + 1
        elseif tok == "--" then
            raw = true
        else
            local name = tok:match("^%-%-(.+)$")
            if name then
                open, taken, supplied[name] = name, 0, true
            elseif open then
                taken = taken + 1
            end
        end
    end

    local spec = open and declared[open]
    local collection = spec and (spec.type == "list" or spec.type == "map")
    -- A marked token is a value however it starts, including `--`-prefixed.
    if spec and (collection or taken == 0) and (raw or not arg_lead:match("^%-%-")) then
        return _complete_input_value(spec, arg_lead)
    end

    local out = {}
    for _, name in ipairs(schema.mode_input_names(adapter, mode_name)) do
        if not supplied[name] then out[#out + 1] = "--" .. name end
    end
    return out
end

---Completion for `:Ndap …`, from the fargs `nvim_parse_cmd` split.
---@type ndap.usercmd.subcommand
local function _complete_subs(_, rest, arg_lead)
    if #rest == 0 then return _debug_subs end
    if rest[1] == "breakpoint" then
        return _bp_complete({ unpack(rest, 2) })
    end
    if rest[1] == "view" then
        return #rest == 1 and _view_subs or {}
    end
    if rest[1] == "start_file" and #rest == 1 then
        return M.complete_filename(arg_lead, "file")
    end
    if rest[1] == "start" then
        return _start_complete(require("ndap.run.schema"), { unpack(rest, 2) }, arg_lead)
    end
    if rest[1] == "adapter_info" then
        -- Positional: [adapter] [mode]; no argument lists every adapter name.
        local schema = require("ndap.run.schema")
        if #rest == 1 then return ndap.available_adapters() end
        if #rest == 2 then return schema.mode_names(rest[2]) end
        return {}
    end
    if rest[1] == "new_run_file" then
        -- Positional: <adapter> [mode] [path]. The path names a new file to
        -- create, so it has no completion.
        local schema = require("ndap.run.schema")
        local used   = { unpack(rest, 2) }
        local pos    = #used + 1 -- 1-based position of the token being completed
        if pos == 1 then
            return ndap.available_adapters()
        elseif pos == 2 then
            return schema.mode_names(used[1])
        end
        return {}
    end
    return {}
end

-- Execution and completion take the same split: the user command's `opts.fargs`
-- on the way in, and `nvim_parse_cmd` (the same <f-args> rules) on the way out.
-- A backslash escapes a space or another backslash; quotes are literal.

---A completion callback for a subcommand: the command name, the fargs after it
---(up to the token being completed), and that token.
---@alias ndap.usercmd.subcommand fun(cmd:string,rest:string[],arg_lead:string):string[]

---Escape `name` for use as one `<f-args>`-split command argument. Only
---backslash and whitespace are special there, so escaping anything else (as
---`fnameescape()` does) would corrupt the argument instead of protecting it.
---@param name string
---@return string
function M.escape_arg(name)
    return (name:gsub("\\", "\\\\"):gsub("[ \t]", { [" "] = "\\ ", ["\t"] = "\\\t" }))
end

---Filename completion for a command argument. `arg_lead` arrives escaped as
---typed, but `getcompletion()` returns nothing for a pattern ending in an
---escaped whitespace ("a\ "), so spell whitespace literally there -- the
---pattern means the same either way. Matches come back unescaped; escape them
---so that `M.complete`'s filter and the command line both see valid arguments.
---@param arg_lead string
---@param type string e.g. "file", "dir"
---@return string[]
function M.complete_filename(arg_lead, type)
    local pattern = arg_lead:gsub("\\([ \t])", "%1")
    return vim.tbl_map(M.escape_arg, vim.fn.getcompletion(pattern, type))
end

---The `complete` callback for `:Ndap`, in the shape `nvim_create_user_command`
---calls: re-split the raw line the way <f-args> would, then hand the pieces to
---`_complete_subs`.
---@param arg_lead string
---@param cmd_line string
---@return string[]
function M.complete(arg_lead, cmd_line)
    ---@param strs string[]?  candidates to filter
    ---@return string[]
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    -- nvim_parse_cmd splits exactly as <f-args> does, and strips any range or
    -- command modifiers. It throws on a command line it cannot parse.
    local ok, parsed = pcall(vim.api.nvim_parse_cmd, cmd_line, {})
    if not ok then return {} end

    -- A non-empty `arg_lead` is the argument currently being completed, so the
    -- last parsed argument is that same word, not context for it. An empty
    -- `arg_lead` means a new argument has begun (or none was typed), leaving
    -- every parsed argument as context.
    local rest = parsed.args or {}
    if arg_lead ~= "" then
        rest[#rest] = nil
    end

    return filter(_complete_subs(parsed.cmd, rest, arg_lead))
end

---Run a `:Ndap …` invocation, exactly as the `:Ndap` callback hands it over.
---The `setup()` guard has already run by the time init calls this.
---@param cmd  string
---@param args string[]
---@param opts table   the user-command opts (`opts.range`)
function M.run(cmd, args, opts)
    _debug_run(cmd, args, opts)
end

return M
