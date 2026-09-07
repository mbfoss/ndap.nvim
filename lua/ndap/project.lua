---@brief The project root, and the path of its state file.
---
---The root is the nearest ancestor of the cwd (cwd included) holding one of
---`config.root_markers` (default `.git`); the state file sits at that root
---under `config.data_filename`.
---
---Split out of `store` so the lazy-load path can ask whether a project has
---saved state without pulling in the persistence machinery: this module needs
---nothing but `config`.

local M              = {}

local config         = require("ndap.config").current

local _root          = nil ---@type string|nil
local _root_resolved = false

---Walk up from the cwd until a directory holding a root marker is found.
---@return string|nil root
local function _find_root()
    local markers = config.root_markers
    if not markers or #markers == 0 then return nil end
    local cwd = vim.fn.getcwd() --[[@as string]]
    local marker = vim.fs.find(markers, { path = cwd, upward = true, limit = 1 })[1]
    return marker and vim.fs.dirname(marker) or nil
end

---The current project root, or nil when the cwd is not inside a project.
---The result is cached; call invalidate() after a cwd change.
---@return string|nil
function M.root()
    if not _root_resolved then
        _root          = _find_root()
        _root_resolved = true
    end
    return _root
end

---Drop the cached root so the next root() recomputes it. Call after a cwd change.
function M.invalidate()
    _root, _root_resolved = nil, false
end

---Absolute path of the data file, or nil when the cwd is not in a project.
---@return string|nil path
function M.data_path()
    assert(config.data_filename and config.data_filename ~= "")
    local root = M.root()
    if not root then return nil end
    return vim.fs.joinpath(root, config.data_filename)
end

return M
