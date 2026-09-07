---@brief Project-scoped persistence for ndap.nvim.
---
---The project root is the nearest ancestor of the cwd (cwd included) that
---contains one of `config.root_markers` (default `.git`). All project state
---is kept in a single JSON file at that root (`config.data_filename`).
---
---This module is a thin path + read/write helper: it converts paths to/from a
---portable project-relative form and reads/writes the data file, over the root
---`ndap.project` locates. It knows nothing about *what* is stored: the
---lifecycle and the breakpoint/expression payloads are in init.lua.

local M = {}

local fsutil     = require("ndap.util.fsutil")
local project    = require("ndap.project")

-- Root and data-path resolution is in `project`, which the lazy-load path
-- uses on its own. Re-exported here so `store` stays the one place callers
-- need for anything project-state.
M.root           = project.root
M.invalidate     = project.invalidate
M.data_path      = project.data_path

---True when a table holds no data: empty, or only (recursively) empty tables.
---@param  tbl table
---@return boolean
local function _is_empty(tbl)
    for _, v in pairs(tbl) do
        if type(v) ~= "table" or not _is_empty(v) then return false end
    end
    return true
end

---Make an absolute path relative to the project root, for portable storage.
---Paths outside the project (or when there is no project) pass through unchanged.
---@param  path string
---@return string
function M.relativize(path)
    local root = M.root()
    if not root then return path end
    local prefix = root .. "/"
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

---Resolve a stored path back to absolute against the project root.
---Already-absolute paths pass through unchanged.
---@param  path string
---@return string
function M.absolutize(path)
    local root = M.root()
    if not root or path:sub(1, 1) == "/" then return path end
    return vim.fs.joinpath(root, path)
end

---Read and decode the project data file. Returns nil when not in a project, or
---when the file is missing or unreadable.
---@return table|nil data
function M.read()
    local path = M.data_path()
    if not path then return nil end
    local ok, content = fsutil.read_content(path)
    if not ok then return nil end
    local dec_ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
    if dec_ok and type(data) == "table" then return data end
    return nil
end

---Encode and write the project data file. No-op when not in a project. When
---`data` holds nothing, any existing file is removed rather than left stale.
---@param  data table
---@return boolean ok
---@return string? err
function M.write(data)
    local path = M.data_path()
    if not path then return true end
    if _is_empty(data) then
        os.remove(path)
        return true
    end
    local ok, json = pcall(vim.json.encode, data)
    if not ok then
        return false, "json encode failed: " .. tostring(json)
    end
    return fsutil.write_content(path, json)
end

return M
