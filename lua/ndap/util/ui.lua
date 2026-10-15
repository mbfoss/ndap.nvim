local M = {}

-- Window options are written local-first: `vim.wo[win][0][opt] = val` touches
-- `win` alone. `vim.wo[win][opt] = val` acts like `:set` (see `:h vim.wo`) and
-- writes the option's global value too, so freshly created windows -- floats
-- especially -- would inherit our settings.
--
-- This is that write for an option named at runtime, plus the `nil` case below,
-- which the index form cannot express.
---@param win integer
---@param opt string
---@param val any  nil resets the option to its global value
function M.win_setlocal(win, opt, val)
    if val == nil then
        -- `= nil` sets "" rather than handing the option back to its global
        -- value; `:setlocal opt<` is what does that.
        vim.api.nvim_win_call(win, function() vim.cmd("setlocal " .. opt .. "<") end)
        return
    end
    vim.wo[win][0][opt] = val
end

---Whether `winid` is a normal, editable window: valid, not a float/popup, and not
---pinned with `winfixbuf`.
---@param winid integer
---@return boolean
local function _is_regular_win(winid)
    if not vim.api.nvim_win_is_valid(winid) then return false end
    local cfg = vim.api.nvim_win_get_config(winid)
    if cfg.relative ~= "" then return false end         -- skip popups
    if vim.wo[winid][0].winfixbuf then return false end -- skip fixed windows
    return true
end

--- The buffer, if any, named exactly `path`. `vim.fn.bufnr()` looks like the tool
--- for this but matches its argument as a pattern and, when nothing matches
--- exactly, settles for a partial match -- so it answers with buffers that merely
--- spell like the path, and chokes on a name holding a regex metacharacter.
---
--- `path` is expanded first, since that is what `nvim_buf_set_name` does with a
--- relative or bare name and so what the buffer is named by the time we look.
---@param path string
---@return integer           -- -1 when no buffer has that name
local function _bufnr_by_name(path)
    path = vim.fn.fnamemodify(path, ":p")

    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(bufnr) == path then return bufnr end
    end

    return -1
end

---@param winid integer
---@param line? integer 1-based line number (nil = just open)
---@param col?  integer 0-based column (nil = column 0)
local function _safe_set_cursor_pos(winid, line, col)
    if not (line and type(line) == 'number' and line > 0) then return end
    if not vim.api.nvim_win_is_valid(winid) then return end
    local bufnr = vim.api.nvim_win_get_buf(winid)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local maxline = vim.api.nvim_buf_line_count(bufnr)
    line = math.min(line, maxline)
    local line_length = #vim.api.nvim_buf_get_lines(bufnr, line - 1, line, true)[1]
    if col and type(col) == 'number' and col >= 0 then
        col = math.min(col, line_length)
    else
        col = 0
    end
    vim.api.nvim_win_set_cursor(winid, { line, col })
end

---@return number winid
local function _get_regular_window()
    local cur_win = vim.api.nvim_get_current_win()
    if _is_regular_win(cur_win) then
        return cur_win
    end

    local tabpage = vim.api.nvim_get_current_tabpage()
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
        if winid ~= cur_win and _is_regular_win(winid) then
            return winid
        end
    end

    vim.cmd('vsplit')
    local newwin = vim.api.nvim_get_current_win()
    -- A split inherits window-local options from its parent, so splitting off a
    -- winfixbuf panel yields a winfixbuf window too; clear it so a file can load.
    M.win_setlocal(newwin, "winfixbuf", false)
    return newwin
end


---Open `buffer` as a floating window and clean its augroup up on `WinClosed`.
---@param buffer   integer                    buffer to display, or 0 for the current buffer
---@param enter    boolean                    enter the window (make it the current window)
---@param config   vim.api.keyset.win_config  window configuration
---@param on_close fun()                      called once, when the window closes
---@return integer winid
---@return integer augroup
function M.create_window(buffer, enter, config, on_close)
    local win = vim.api.nvim_open_win(buffer, enter, config)
    local augroup = vim.api.nvim_create_augroup("ndap_window_#" .. win, { clear = true })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        callback = function(args)
            local closedwin = tonumber(args.match)
            if closedwin == win then
                vim.api.nvim_del_augroup_by_id(augroup)
                on_close()
            end
        end
    })
    return win, augroup
end

--- A scratch buffer; `buffer_options` override the defaults. `filetype` is set
--- last, after `on_delete` is hooked up, so `FileType` handlers see the final
--- options and a deletion from one still reaches `on_delete`.
---@param listed boolean
---@param buffer_options vim.bo?
---@param on_delete function?
function M.create_scratch_buffer(listed, buffer_options, on_delete)
    local buf = vim.api.nvim_create_buf(listed, true)
    local bo = { ---@type vim.bo
        buftype = "nofile",
        swapfile = false,
        modeline = false,
    }
    if not listed then
        bo.bufhidden = 'wipe'
    end
    if buffer_options then
        for k, v in pairs(buffer_options) do
            bo[k] = v
        end
    end
    local filetype = bo.filetype
    bo.filetype = nil
    for k, v in pairs(bo) do
        vim.bo[buf][k] = v
    end
    if on_delete then
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            buffer = buf,
            once = true,
            callback = function(ev)
                on_delete()
            end,
        })
    end
    if filetype then
        vim.bo[buf].filetype = filetype
    end
    return buf
end

---@param filepath string
---@param line? integer 1-based line number (nil = just open)
---@param col?  integer 0-based column (nil = column 0)
---@param activate boolean? activates the file window
---@return number winid or -1
---@return number bufnr or -1
function M.smart_open_file(filepath, line, col, activate)
    if line and line < 1 then line = nil end
    if col and col < 0 then col = nil end
    if not filepath or filepath == "" then return -1, -1 end

    -- Absolute + symlink-resolved: bufadd() expands relative paths against the
    -- cwd, so an un-absolutized name can resolve to a different buffer.
    local full_path = vim.fn.resolve(vim.fn.fnamemodify(filepath, ":p"))

    -- Exact-path lookup/create, no glob or fuzzy fallback. bufadd() only makes
    -- the (unloaded) entry; `:buffer` below does the reading.
    local bufnr = vim.fn.bufadd(full_path)
    if bufnr == 0 then
        return -1, -1
    end

    -- Already in the current window: nothing to switch to.
    local cur_win = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_get_buf(cur_win) == bufnr then
        _safe_set_cursor_pos(cur_win, line, col)
        return cur_win, bufnr
    end

    -- Reuse another window already showing this buffer.
    local tabpage = vim.api.nvim_get_current_tabpage()
    for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_get_tabpage(winid) == tabpage and _is_regular_win(winid) then
            if activate ~= false then
                vim.api.nvim_set_current_win(winid)
            end
            _safe_set_cursor_pos(winid, line, col)
            return winid, bufnr
        end
    end

    local winid = _get_regular_window()
    if activate ~= false then
        vim.api.nvim_set_current_win(winid)
    end

    -- pcall is required here: the load can abort for reasons the caller cannot
    -- check for up front -- an existing swap file the user answers "quit" to, an
    -- unreadable file, E37 on a modified buffer under 'nohidden' -- and an
    -- uncaught Vim error unwinds into the picker callback as a stack traceback.
    local ok, err = pcall(vim.fn.win_execute, winid, "buffer " .. bufnr)
    if not ok or not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr then
        -- Aborted: leave the window on whatever it was showing, and leave the
        -- buffer unlisted so a failed open does not litter `:ls`.
        if not ok and err and err ~= "" then
            vim.notify("ndap: " .. tostring(err), vim.log.levels.WARN)
        end
        return -1, -1
    end
    vim.bo[bufnr].buflisted = true

    vim.api.nvim_win_set_buf(winid, bufnr)
    _safe_set_cursor_pos(winid, line, col)
    return winid, bufnr
end

---@param bufnr integer
---@param line? integer 1-based line number (nil = just open)
---@param col?  integer 0-based column (nil = column 0)
---@param activate? boolean focus the target window (default true)
---@return number winid
function M.smart_open_buffer(bufnr, line, col, activate)
    local cur_win = vim.api.nvim_get_current_win()
    local winid = _get_regular_window()
    if activate ~= false then
        vim.api.nvim_set_current_win(winid)
    elseif vim.api.nvim_win_is_valid(cur_win) then
        -- `_get_regular_window` may have split one off and entered it.
        vim.api.nvim_set_current_win(cur_win)
    end
    vim.fn.win_execute(winid, "buffer " .. bufnr)
    _safe_set_cursor_pos(winid, line, col)
    return winid
end

---@param msg string
---@param default_yes boolean
---@param callback fun(confirmed: boolean|nil)
function M.confirm_action(msg, default_yes, callback)
    local choices = "&Yes\n&No"
    local default = default_yes and 1 or 2

    local ok, choice = pcall(vim.fn.confirm, msg, choices, default)
    if not ok then
        callback(nil)
        return
    end
    if choice == 1 then
        callback(true)
    elseif choice == 2 then
        callback(false)
    else
        callback(nil)
    end
end

---Pull content down into any blank space at the bottom of a window so the viewport
---stays full instead of showing a few lines over a field of `~`. Scrolls the view
---only (never the cursor), and only when there are earlier lines to pull down.
---@param winid integer
function M.fill_viewport(winid)
    if not vim.api.nvim_win_is_valid(winid) then return end
    local h    = vim.api.nvim_win_get_height(winid)
    local info = vim.fn.getwininfo(winid)[1]
    if not info then return end

    local visible = info.botline - info.topline + 1
    if visible >= h or info.topline <= 1 then return end

    vim.api.nvim_win_call(winid, function()
        local view   = vim.fn.winsaveview()
        view.topline = math.max(1, view.topline - (h - visible))
        vim.fn.winrestview(view)
    end)
end

---Whether a loaded buffer already carries this name, matched the way
---`unique_buf_name` matches (the buffer's full, normalized name).
---@param name string
---@return boolean
function M.buf_name_taken(name)
    return _bufnr_by_name(name) ~= -1
end

---Return `basename` if no buffer has that name, otherwise `basename~1`, `basename~2`, …
---@param basename string
---@return string
function M.unique_buf_name(basename)
    local name = basename
    local n    = 0
    while M.buf_name_taken(name) do
        n    = n + 1
        name = basename .. "~" .. n
    end
    return name
end

---A run buffer's canonical name: `ndap://<number>/<name>:<type>`, carrying its
---run's number and group name, distinguished by kind (`:b ndap://1/debug app:log`).
---Pair with `unique_buf_name` when the name may already be taken.
---@param number integer  the run number
---@param name string     the run group name
---@param kind string     buffer kind, e.g. "log", "repl", "output"
---@return string
function M.run_buf_name(number, name, kind)
    return ("ndap://%d/%s:%s"):format(number, name, kind)
end

return M
