-- shared functions: public API

local M = {}

-- Re-exported so registry adapters (under `ndap-adapters/`) depend only on
-- `ndap.shared`, not on the plugin's internal module layout.

---Spawn a command in a terminal buffer; see `ndap.util.term.spawn`.
---@type fun(cmd: string|string[], opts: ndap.util.SpawnOpts, bufnr?: integer): ndap.util.TermHandle?, string?
M.spawn = require("ndap.util.term").spawn

---Expand one candidate path from a lookup list: `$VAR` and `~` expand wherever
---they appear, as `vim.fs.normalize` does everywhere else, and a relative entry is
---taken against `cwd` when one is given. An entry naming a variable that is unset
---or empty is nil, so the caller skips it. `${VAR}` braces are not expanded. Pass
---no `cwd` for a list of programs, where a bare name is meant to be looked up on
---$PATH rather than resolved against a directory.
---@param path string
---@param cwd? string  base for relative entries; without it they are left as-is
---@return string?
function M.expand_path(path, cwd)
    -- `vim.fs.normalize` leaves an unset variable literal and collapses an empty
    -- one ("$V" becomes ".", "$V/bin/py" becomes "/bin/py"). Neither is a path the
    -- user asked for, and "." would pass `is_directory`; an empty variable does not
    -- survive normalization in any recognizable form, so check before expanding.
    for var in path:gmatch("%$([%w_]+)") do
        local value = vim.env[var]
        if not value or value == "" then return nil end
    end
    path = vim.fs.normalize(path)
    if cwd and not path:match("^~") and vim.fn.isabsolutepath(path) == 0 then
        path = vim.fs.normalize(vim.fs.joinpath(cwd, path))
    end
    return path
end

---A path as an adapter body wants it: `~` and `$VAR` expanded by `vim.fs.normalize`,
---which leaves an unset variable literal. Nil in, nil out. Anything else raises,
---which a mode's `build` turns into the run's abort message.
---@param path string?
---@return string?
function M.normalize_path(path)
    if path == nil then return nil end
    if type(path) ~= "string" then
        error(("normalize_path: expected a string, got %s"):format(type(path)), 2)
    end
    return vim.fs.normalize(path)
end

---@param list string[]?
---@return string[]?
function M.normalize_paths(list)
    if list == nil then return nil end
    if type(list) ~= "table" then
        error(("normalize_paths: expected a list, got %s"):format(type(list)), 2)
    end
    local out = {}
    for i, entry in ipairs(list) do out[i] = M.normalize_path(entry) end
    return out
end

---One port input, held to the range a port has. Returns the port unchanged, or nil
---and a message: the `nil, err` pair `build` returns to abort a run:
---`local port, err = shared.resolve_port(parameters.port)`. An unset optional input is
---nil in and nil out, with no error, so only a written value is checked.
---@param port integer?  a port input's value
---@return integer? port, string? err
function M.resolve_port(port)
    if port == nil then return nil end
    if port < 0 or port > 65535 then
        return nil, ("port out of range (0-65535), got %s"):format(port)
    end
    return port
end

---An unused TCP port, taken by binding port 0 and letting the kernel pick.
---Errors if no port can be taken, rather than returning one nobody can bind.
---@return integer
function M.free_port()
    local tcp = assert(vim.uv.new_tcp(), "uv.new_tcp failed")
    -- `bind` fails by returning, not raising, and a socket that failed to bind
    -- still answers `getsockname` with port 0, so the bind is what says whether
    -- the port is real. Closing unconditionally leaves no handle to the GC.
    local bound, err = tcp:bind("127.0.0.1", 0)
    local addr = bound and tcp:getsockname()
    tcp:close()
    if not (addr and addr.port and addr.port > 0) then
        error("free_port: " .. tostring(err or "no port was assigned"), 2)
    end
    return addr.port
end

---Walk a list of candidate locations and return the first one `accept` approves,
---alongside every candidate actually tried (for an error message naming them).
---Entries are expanded by `expand_path` (`$VAR` and `~` anywhere, a relative entry
---against `opts.cwd`, and an unset or empty variable skipping the entry) and
---de-duplicated. Entries are literal paths, with no globbing.
---@param candidates string[]  lookup list, in preference order
---@param accept fun(path: string): boolean  the test a usable candidate passes
---@param opts? { cwd?: string }
---@return string? found, string[] tried
function M.resolve_path(candidates, accept, opts)
    opts = opts or {}
    local tried, seen = {}, {}
    for _, cand in ipairs(candidates) do
        local path = M.expand_path(cand, opts.cwd)
        if path and not seen[path] then
            seen[path] = true
            tried[#tried + 1] = path
            if accept(path) then return path, tried end
        end
    end
    return nil, tried
end

---`accept` for `resolve_path` when the candidate must be a runnable program.
---@param path string
---@return boolean
function M.is_executable(path) return vim.fn.executable(path) == 1 end

---`accept` for `resolve_path` when the candidate must be an existing directory.
---@param path string
---@return boolean
function M.is_directory(path) return vim.fn.isdirectory(path) == 1 end

---The process id to attach to: the one already given, or one picked interactively.
---What an attach mode's `build` calls for its `pid` input, which is why no adapter
---marks it `required`. Yields (see `select_process`) only when `pid` is nil.
---@param pid integer?  the pid supplied as an input, if any
---@param prompt? string  select prompt
---@return integer? pid, string? err
function M.resolve_pid(pid, prompt)
    -- Not `pid or select_process(…)`: `or` would truncate the call to one value
    -- and drop the error, leaving a cancelled pick indistinguishable from a
    -- successful one.
    if pid then return pid end
    return M.select_process(prompt or "Select process")
end

---Pick a running process interactively, via `vim.ui.select`. This yields: it must be
---called from inside a coroutine, and resumes it with the choice once the user picks.
---@param prompt? string  select prompt (default "Select process")
---@return integer? pid, string? err
function M.select_process(prompt)
    local co = coroutine.running()
    if not co then
        return nil, "select_process must be called from a coroutine"
    end
    -- No `ps` here: say so rather than report an empty process list.
    if vim.fn.has("win32") == 1 then
        return nil, "Process selection is not available on Windows; pass a pid"
    end

    local lines = vim.fn.systemlist("ps -eo pid,user,comm 2>/dev/null")
    if not lines or #lines == 0 then
        return nil, "No processes found"
    end

    ---@type {label:string, pid:string}[]
    local choices = {}
    for _, line in ipairs(lines) do
        -- A header has no numeric first field, so it drops out here.
        local pid, user, name = line:match("^%s*(%d+)%s+(%S+)%s+(.-)%s*$")
        if pid then
            choices[#choices + 1] = {
                label = ("%8s | %s - %s"):format(pid, user, name),
                pid   = pid,
            }
        end
    end
    if #choices == 0 then return nil, "No processes found" end

    -- Hands the answer back to the yielded caller. Everything that caller still has
    -- to do runs inside this resume, so a failure in it surfaces here or not at all:
    -- `coroutine.resume` returns false instead of raising, and no one is above us.
    ---@param pid string?  chosen pid as `ps` printed it, or nil when the picker was dismissed
    local function answer(pid)
        local ok, err = coroutine.resume(co, pid)
        if not ok then
            vim.notify("ndap: " .. tostring(err), vim.log.levels.ERROR)
        end
    end

    vim.schedule(function()
        local labels = vim.tbl_map(function(c) return c.label end, choices)
        vim.ui.select(labels, { prompt = type(prompt) == "string" and prompt or "Select process" }, function(selected)
            if not selected then
                answer(nil)
                return
            end
            for _, c in ipairs(choices) do
                if c.label == selected then
                    answer(c.pid)
                    return
                end
            end
            answer(nil)
        end)
    end)

    local pid = coroutine.yield()
    if not pid then return nil, "Process selection cancelled" end
    return tonumber(pid)
end

return M
