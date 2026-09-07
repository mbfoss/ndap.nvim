---@brief run_file scaffolding for `:Ndap new_run_file`.
---
---Writes a runnable Lua run_file for an adapter + one of its `modes`. The
---generated file is mode-based, exactly like `:Ndap start`: it names the
---`adapter` and `mode` and lists that mode's declared inputs under
---`parameters`, each seeded with a starting value (`ndap.run.inputs`' `seed`) and
---annotated with its `description`. `:Ndap start_file` resolves it through the
---mode's `build` (see `ndap.run.schema`), so a run file and `:Ndap start`
---share one description of a mode, its `inputs`, and never drift.

local schema = require("ndap.run.schema")
local inputs_registry = require("ndap.run.inputs")

local M = {}

---@param msg string
local function _warn(msg) vim.notify("[ndap] " .. msg, vim.log.levels.WARN) end

---@param msg string
local function _err(msg) vim.notify("[ndap] " .. msg, vim.log.levels.ERROR) end

---Render a seed value as Lua source. Seeds are simple (strings, numbers, booleans
---and (usually empty) tables), so this handles just those, emitting a one-line
---literal; array-like and map-like tables are both rendered inline.
---@param v any
---@return string
local function _lua_literal(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        if next(v) == nil then return "{}" end
        local parts = {}
        if vim.islist(v) then
            for _, item in ipairs(v) do parts[#parts + 1] = _lua_literal(item) end
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                parts[#parts + 1] = ("[%q] = %s"):format(k, _lua_literal(v[k]))
            end
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "nil"
end

---Build the `parameters = { … }` lines for a mode: one `name = <seed>,` entry per
---declared input, sorted, each trailed by a `-- description`. Required inputs are
---written active, the rest commented out. Returns nil when no inputs are declared.
---@param adapter string
---@param mode_name string
---@return string[]?  the interior lines, already indented to sit inside `parameters`
local function _input_lines(adapter, mode_name)
    local names = schema.mode_input_names(adapter, mode_name)
    if #names == 0 then return nil end
    local specs = schema.mode_inputs(adapter, mode_name)

    -- Two passes: build each input's code (a `name = <seed>,` assignment, commented
    -- out unless the input is required), then pad them all to a common width so the
    -- trailing `-- description` comments line up.
    local codes, width = {}, 0
    for i, name in ipairs(names) do
        local assign = ("%s = %s,"):format(name, _lua_literal(inputs_registry.seed(specs[name])))
        codes[i] = specs[name].required and assign or ("-- " .. assign)
        width = math.max(width, #codes[i])
    end

    local lines = {}
    for i, name in ipairs(names) do
        local comment = specs[name].description or ""
        -- An input that names its values says them here too, so the file shows what
        -- may be written without having to run completion: `e.g.`, since nothing
        -- rejects a value written past them. Only a written-out set reads as a
        -- comment; a source or a function is completion's to answer.
        if vim.islist(specs[name].completion) then
            local listed = "e.g. " .. table.concat(specs[name].completion, "|")
            comment = comment == "" and listed or (comment .. ": " .. listed)
        end
        local line = "        " .. codes[i]
        if comment ~= "" then
            line = line .. string.rep(" ", width - #codes[i]) .. "  -- " .. comment
        end
        lines[i] = line
    end
    return lines
end

---Write a run_file for an `adapter` + one of its `modes` and open it for
---editing; start it with `:Ndap start_file`. `assignments` is positional: adapter, then
---optional mode (defaults to the sole one) and path. Fails if the path exists.
---@param assignments string[]  positional adapter, mode, path, e.g. { "codelldb", "binary", "./foo.lua" }
---@return string? path  the file that was created
function M.new_run_file(assignments)
    -- Every argument is positional: `new_run_file <adapter> [mode] [path]`.
    local adapter, mode_name, path
    for _, tok in ipairs(assignments or {}) do
        if not adapter then
            adapter = tok
        elseif not mode_name then
            mode_name = tok
        elseif not path then
            path = tok
        else
            _warn("new_run_file: unexpected argument '" .. tok ..
                "' (usage: new_run_file <adapter> [mode] [path])")
            return
        end
    end

    if not adapter or adapter == "" then
        _warn("new_run_file: usage: new_run_file <adapter> [mode] [path]")
        return
    end
    local base, load_err = require("ndap").load_adapter(adapter)
    if not base then
        _err("new_run_file: " .. (load_err
            and ("adapter " .. adapter .. " failed to load: " .. load_err)
            or ("unknown adapter: " .. adapter .. " (available: "
                .. table.concat(require("ndap").available_adapters(), ", ") .. ")")))
        return
    end

    -- Resolve the mode: given, else the adapter's sole mode; reject an
    -- adapter that declares none, or an ambiguous choice among several.
    local names = schema.mode_names(adapter)
    if #names == 0 then
        _err("new_run_file: adapter " .. adapter .. " declares no modes")
        return
    end
    if mode_name and mode_name ~= "" then
        if not vim.tbl_contains(names, mode_name) then
            _err(("new_run_file: adapter %s has no mode %q (available: %s)")
                :format(adapter, mode_name, table.concat(names, ", ")))
            return
        end
    elseif #names == 1 then
        mode_name = names[1]
    else
        _err(("new_run_file: adapter %s has multiple modes, pick one (available: %s)")
            :format(adapter, table.concat(names, ", ")))
        return
    end

    -- Resolve the destination; fail rather than clobber or rename an existing file.
    local root = require("ndap.store").root() or vim.fn.getcwd()
    local dest = (path and path ~= "") and vim.fn.fnamemodify(vim.fn.expand(path), ":p")
        or vim.fs.joinpath(root, adapter .. "_" .. mode_name .. ".lua")
    if not dest:match("%.lua$") then dest = dest .. ".lua" end
    if vim.uv.fs_stat(dest) then
        _err("new_run_file: file already exists: " .. dest)
        return
    end

    local lines = {
        "-- ndap run file",
        "return {",
        ("    name       = %q,"):format(adapter),
        ("    adapter    = %q,"):format(adapter),
        ("    mode       = %q,"):format(mode_name),
    }
    -- The mode's declared inputs are answered under `parameters`. A mode with
    -- no inputs gets an empty `parameters` rather than a `{` / blank line / `}`
    -- sandwich.
    local input_lines = _input_lines(adapter, mode_name)
    if not input_lines then
        lines[#lines + 1] = "    parameters = {},"
    else
        lines[#lines + 1] = "    parameters = {"
        vim.list_extend(lines, input_lines)
        lines[#lines + 1] = "    },"
    end
    vim.list_extend(lines, { "}", "" })

    local ok, werr = require("ndap.util.fsutil").write_content(dest, table.concat(lines, "\n"))
    if not ok then
        _err("new_run_file: failed to write " .. dest .. ": " .. tostring(werr))
        return
    end
    require("ndap.util.ui").smart_open_file(vim.fn.fnameescape(dest))
    return dest
end

return M
