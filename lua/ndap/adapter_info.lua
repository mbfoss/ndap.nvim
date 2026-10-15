---@brief The adapter reference behind `:Ndap adapter_info`.
---
---An adapter definition documents itself: every mode carries a `description`
---and a `request`, every input a type, the values it completes with and a line on
---what it means (see `ndap.Input` in `meta.lua`). This module is the
---reader for that: it loads one adapter's definition, checks it, and renders
---what it declares as markdown in a float, so the same declaration that
---`:Ndap run` validates against and `new_run_file` seeds from is what is shown.
---
---Nothing here is written by hand, so an adapter you wrote yourself, or a
---definition you edited in your own config, documents itself exactly as the
---shipped ones do.

local schema = require("ndap.run.schema")

local M = {}

---How wide `text` lands on screen: its display width, less the markup the float
---hides. `markdown_inline` conceals code-span backticks and emphasis delimiters,
---so the cell markup below costs no columns.
---@param text string
---@return integer
local function _width(text)
    local shown = text:gsub("`", ""):gsub("%*%*", "")
    return vim.fn.strdisplaywidth(shown)
end

---A box-drawn table, its columns padded to a common width. Drawn rather than left
---to markdown because a pipe-and-dash table only lines up while its markers are
---on screen, where ruled borders survive the conceal that makes the cell markup
---pay off.
---@param headers string[]
---@param rows string[][]
---@param out string[]  appended to
local function _table(headers, rows, out)
    -- Measured as displayed, not in bytes: a cell holding an em dash, or the
    -- backticks around a type, would otherwise come out short by the difference
    -- and break the column.
    local width = _width

    local widths = {}
    for i, head in ipairs(headers) do widths[i] = width(head) end
    for _, row in ipairs(rows) do
        for i, cell in ipairs(row) do widths[i] = math.max(widths[i] or 0, width(cell)) end
    end

    ---@param cells string[]
    local function row_line(cells)
        local parts = {}
        for i = 1, #headers do
            local cell = cells[i] or ""
            parts[i] = cell .. (" "):rep(widths[i] - width(cell))
        end
        return "│ " .. table.concat(parts, " │ ") .. " │"
    end

    ---@param left string
    ---@param join string
    ---@param right string
    local function rule(left, join, right)
        local parts = {}
        for i = 1, #headers do parts[i] = ("─"):rep(widths[i] + 2) end
        return left .. table.concat(parts, join) .. right
    end

    out[#out + 1] = rule("┌", "┬", "┐")
    out[#out + 1] = row_line(headers)
    out[#out + 1] = rule("├", "┼", "┤")
    for _, r in ipairs(rows) do out[#out + 1] = row_line(r) end
    out[#out + 1] = rule("└", "┴", "┘")
end

---How an input's value is written, as the definition declares it: the scalar's
---own type, or the entry type of a collection.
---@param input ndap.Input
---@return string
local function _type_of(input)
    local kind = input.type or "string"
    if kind == "list" or kind == "map" then
        return input.item_type and (kind .. " of " .. input.item_type) or kind
    end
    return kind
end

---An input's description, with the values it completes with folded in: they are
---part of what the input means, and completion is not available in a float,
---behind a `[required]` marker for the inputs a run fails without. `e.g.`, not
---"one of": nothing rejects a value written past them. Only a written-out set is
---shown; a source or a function is completion's to answer.
---@param input ndap.Input
---@return string
local function _description_of(input)
    local text = input.description or ""
    if vim.islist(input.completion) and #input.completion > 0 then
        local quoted = vim.tbl_map(function(c) return ("`%s`"):format(c) end, input.completion --[[@as table]])
        local listed = "e.g. " .. table.concat(quoted, ", ")
        text = text == "" and listed or (listed .. "; " .. text)
    end
    if input.required then
        -- Inside the code span the brackets are text, not a shortcut link whose
        -- own brackets the float would conceal.
        text = text == "" and "`[required]`" or ("`[required]` " .. text)
    end
    return text
end

---One mode's subsection: its heading, then a row per declared input. Required
---inputs sort first, since those are the ones a run fails without.
---@param adapter string
---@param mode_name string
---@param out string[]  appended to
local function _mode_block(adapter, mode_name, out)
    local mode = schema.mode(adapter, mode_name)
    if not mode then return end

    out[#out + 1] = ("### %s (%s)"):format(mode_name, mode.request or "?")
    if mode.description and mode.description ~= "" then
        out[#out + 1] = ""
        out[#out + 1] = mode.description
    end
    out[#out + 1] = ""

    local specs = schema.mode_inputs(adapter, mode_name)
    local names = schema.mode_input_names(adapter, mode_name)
    if #names == 0 then
        out[#out + 1] = "(no inputs)"
        return
    end

    -- Required first, then alphabetical, matching the order `new_run_file`
    -- writes them in: what must be answered, then what may be.
    table.sort(names, function(a, b)
        local ra, rb = specs[a].required or false, specs[b].required or false
        if ra ~= rb then return ra end
        return a < b
    end)

    local rows = {}
    for i, name in ipairs(names) do
        -- Code spans, so the markdown highlighter colours the name and the type
        -- apart from the prose beside them.
        rows[i] = {
            ("`%s`"):format(name),
            ("`%s`"):format(_type_of(specs[name])),
            _description_of(specs[name]),
        }
    end
    _table({ "input", "type", "description" }, rows, out)
end

---Every registered adapter name. What `:Ndap adapter_info` shows when it is not
---asked about one in particular: names only, so listing them loads no definition.
---@return string[]
function M.overview()
    local names = require("ndap").available_adapters()

    local out = { ("## adapters (%d)"):format(#names), "" }
    for _, name in ipairs(names) do out[#out + 1] = "- `" .. name .. "`" end
    vim.list_extend(out, {
        "",
        "Use `:Ndap adapter_info <adapter>` to load an adapter module and report its modes and inputs",
    })
    return out
end

---Extract the executable name from an adapter's `command` field.
---@param command string|string[]|nil
---@return string? exe
local function _exe_of(command)
    if type(command) == "table" then return command[1] end
    if type(command) == "string" then return command end
    return nil
end

---Where the executable the definition names resolved to, or why it did not.
---An adapter reached over a connection, or provisioned by its `setup`, has
---nothing to verify locally and so says nothing at all.
---@param def ndap.AdapterDef
---@return string? message
local function _tooling(def)
    local exe = _exe_of(def.command)
    if not exe then return nil end

    local resolved = vim.fn.exepath(exe)
    if resolved == "" then
        return ("`%s` not found on PATH"):format(exe)
    end

    -- A table command may point at an adapter file (e.g. a mason-managed .js);
    -- the executable existing does not mean the adapter itself is installed.
    if type(def.command) == "table" then
        for i = 2, #def.command do
            local arg = def.command[i]
            if type(arg) == "string" and arg:sub(1, 1) == "/" and arg:match("%.js$")
                and vim.fn.filereadable(arg) == 0 then
                return ("`%s` found but the adapter file is missing: `%s`"):format(exe, arg)
            end
        end
    end
    return ("`%s` found (`%s`)"):format(exe, resolved)
end

---The `status` section: a bullet per finding, such as where the executable resolved to,
---then anything wrong with the definition. Nothing to report is nothing to say,
---so an adapter that resolves and has nothing to verify locally (a connection, or
---a `setup` that provisions it) skips the section and opens on its modes.
---@param adapter string
---@param out string[]  appended to
local function _report_block(adapter, out)
    local def = require("ndap").load_adapter(adapter)
    local tooling
    if type(def) == "table" then tooling = _tooling(def) end

    local problems = schema.validate(adapter)
    if not tooling and #problems == 0 then return end

    out[#out + 1] = "## status"
    out[#out + 1] = ""
    if tooling then out[#out + 1] = "- " .. tooling end
    for _, problem in ipairs(problems) do
        out[#out + 1] = "- " .. problem
    end
end

---One adapter's reference: a `status` section with what checking its definition
---turned up, then a `modes` section with a subsection per mode. `mode_name` narrows it to that one. Loading the definition is
---what this does; returns nil plus a message when the adapter or mode is not
---registered.
---@param adapter string
---@param mode_name? string
---@return string[]? lines, string? err
function M.render(adapter, mode_name)
    local def, load_err = require("ndap").load_adapter(adapter)
    if not def and not load_err then
        return nil, ("unknown adapter: %s (available: %s)")
            :format(adapter, table.concat(require("ndap").available_adapters(), ", "))
    end

    local names = schema.mode_names(adapter)
    if mode_name and mode_name ~= "" then
        if not vim.tbl_contains(names, mode_name) then
            return nil, ("adapter %s has no mode %q (available: %s)")
                :format(adapter, mode_name, table.concat(names, ", "))
        end
        names = { mode_name }
    end

    -- A definition that did not load is reported by the status section alone:
    -- there are no modes to render behind it.
    local out = {}
    _report_block(adapter, out)
    if not def then return out end

    -- Nothing to report is the common case, and then the page opens on the modes.
    if #out > 0 then out[#out + 1] = "" end
    out[#out + 1] = "## modes"
    if #names == 0 then
        out[#out + 1] = ""
        out[#out + 1] = "(none declared)"
        return out
    end
    for _, name in ipairs(names) do
        out[#out + 1] = ""
        _mode_block(adapter, name, out)
    end
    return out
end

---Show the adapter reference in a float: every registered name when `adapter` is
---nil, otherwise that adapter loaded and checked: what the check turned up, then
---its modes and their inputs, narrowed to `mode_name` when given. Behind
---`:Ndap adapter_info`.
---@param adapter? string
---@param mode_name? string
function M.show(adapter, mode_name)
    local lines, title
    if not adapter or adapter == "" then
        lines, title = M.overview(), "adapters"
    else
        local err
        lines, err = M.render(adapter, mode_name)
        if not lines then
            vim.notify("[ndap] adapter_info: " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        title = mode_name and (adapter .. " " .. mode_name) or adapter
    end
    -- Width measured the same way the table was padded, so the float is as wide
    -- as the page looks rather than as wide as its markup.
    local width = 0
    for _, line in ipairs(lines) do width = math.max(width, _width(line)) end
    require("ndap.util.floatwin").open(table.concat(lines, "\n"),
        { title = title, is_markdown = true, content_width = width })
end

return M
