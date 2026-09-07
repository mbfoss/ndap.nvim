---@brief Health check for ndap.nvim, run with `:checkhealth ndap`.
---
---Reports the Neovim version, whether `setup()` has run, the resolved project /
---store state, the options that differ from the defaults, and which adapters
---are registered, by name only, since inspecting a definition is what
---`:Ndap adapter_info <adapter>` is for.

local M = {}

local health = vim.health

---Whether `setup()` has run, asked without loading the plugin: an unrequired
---ndap is not a fault, it is a config missing the `setup()` call.
---@return boolean
local function _is_setup()
    return package.loaded["ndap"] ~= nil and require("ndap").is_setup()
end

---Check the Neovim version against the plugin's minimum (see `ndap.setup`).
local function _check_requirements()
    if vim.fn.has("nvim-0.10") ~= 1 then
        health.start("ndap: requirements")
        health.error("ndap.nvim requires Neovim >= 0.10")
    end
end

---Report whether the plugin came up, and the resolved project / store state.
local function _check_setup()
    health.start("ndap: setup")

    if _is_setup() then
        health.ok("setup() has run (:Ndap is registered)")
    else
        health.warn("setup() has not been called", {
            "Call require('ndap').setup() from your config (or set `opts` with your plugin manager)",
            "Check that ndap.nvim is on 'runtimepath' (an opt package needs :packadd)",
        })
    end
end

-- Options whose default is `nil`, which no table can hold. Without this an
-- unset-by-default option would be indistinguishable from a misspelled one.
local _OPTIONAL = {
    enabled_adapters = true,
    external_terminal = true,
}

---Collect the options whose value differs from the default, as flat paths
---(`inline_vars`, `symbols.logpoint`) with the value now in force. Lists are
---compared whole rather than descended into: a `root_markers` is one option,
---not one option per marker.
---@param current table
---@param defaults table
---@param prefix string  path of the enclosing table, "" at the top level
---@param out table[]
---@return table[]
local function _diff_config(current, defaults, prefix, out)
    for key, value in pairs(current) do
        local path = prefix .. tostring(key)
        local default = defaults[key]
        if type(value) == "table" and type(default) == "table" and not vim.islist(value) then
            _diff_config(value, default, path .. ".", out)
        elseif not vim.deep_equal(value, default) then
            table.insert(out, {
                path    = path,
                value   = vim.inspect(value),
                unknown = default == nil and not _OPTIONAL[path],
            })
        end
    end
    return out
end

---Report the options that differ from the defaults; the whole config would be
---mostly untouched defaults, and the point here is what this user changed.
---Anything set that the plugin does not define is flagged: `setup()` merges
---`opts` wholesale, so a misspelled option is kept silently.
local function _check_config()
    health.start("ndap: configuration")

    if not _is_setup() then
        health.info("setup() has not run, so every option is at its default")
        return
    end
    local ndap = require("ndap")

    local diffs = _diff_config(require("ndap.config").current, ndap.get_default_config(), "", {})
    table.sort(diffs, function(a, b) return a.path < b.path end)

    if #diffs == 0 then
        health.ok("every option is at its default")
        return
    end

    local lines = {}
    for _, entry in ipairs(diffs) do
        table.insert(lines, ("  %s = %s"):format(entry.path, entry.value))
    end
    health.info(("%d option%s differ from the defaults:\n%s")
        :format(#diffs, #diffs == 1 and "" or "s", table.concat(lines, "\n")))

    for _, entry in ipairs(diffs) do
        if entry.unknown then
            health.warn(("`%s` is not an option ndap defines"):format(entry.path), {
                "Check its spelling against :help ndap-config",
            })
        end
    end
end

---List the registered adapters. Their names come from the registry's filenames,
---so nothing here loads a definition; inspecting one is what
---`:Ndap adapter_info <adapter>` is for. Needs no `setup()`, which only
---contributes the `enabled_adapters` filter.
local function _check_adapters()
    health.start("ndap: adapters")

    local names = require("ndap").available_adapters()
    local allowed = require("ndap.config").current.enabled_adapters
    health.ok(("%d registered: %s"):format(#names, table.concat(names, ", ")))
    if allowed then
        health.info(("`enabled_adapters` is set (%s), so only those are available")
            :format(table.concat(allowed, ", ")))
    elseif not _is_setup() then
        health.info("setup() has not run, so `enabled_adapters` is not filtering this list")
    end
    health.info("Run :Ndap adapter_info <adapter> to see an adapter's modes, inputs and tooling")
end

function M.check()
    _check_requirements()
    _check_setup()
    _check_config()
    _check_adapters()
end

return M
