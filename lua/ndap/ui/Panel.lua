---@brief The single bottom split that shows a run's buffer: the panel.
---
---A run spawns several buffers (Terminal, Output, REPL, adapter log, DAP
---messages); this `ndap.ui.Panel` registers each with a priority and the
---window holds the highest-priority live one. One window is reused for all of
---them: registering a buffer swaps the occupant rather than opening a second
---split.
---
---There being one window shared by every run, a run's label and state have
---nowhere to show; they live in the DebugView instead.

local fixedwin     = require("ndap.util.fixedwin")
local ui_util      = require("ndap.util.ui")
local config       = require("ndap.config").current

local M            = {}

---Whether this window is the panel in play, established by `init`. Everything
---below is inert until then, so `:Ndap panel` before `setup` does nothing.
local _enabled     = false

---One buffer a run registered for display, as passed to `ndap.AddBufOpts`.
---@class ndap.ui.Panel.Entry
---@field bufnr    integer
---@field priority integer
---@field seq      integer  registration order; breaks priority ties toward the newest

---@type ndap.ui.Panel.Entry[]
local _entries     = {}
local _seq         = 0

---@type integer?
local _win         = nil
---fixedwin's autocmd group for `_win`, torn down when the window stops being
---ours so it no longer holds the user's window to our height.
---@type integer?
local _fixed_group = nil
---@type integer?
local _shown       = nil
---The buffer the window held when it was closed, live only for the tick of the
---close: nvim closes the window before announcing the buffer's deletion, so this
---is how `refresh` tells that close apart from the user closing the window.
---@type integer?
local _closed_with = nil
---@type number?
local _ratio       = nil

local _augroup     = vim.api.nvim_create_augroup("ndap.Panel", { clear = true })

local _win_setlocal = ui_util.win_setlocal

---Drop `bufnr`, plus any entry whose buffer is already gone. Buffer numbers are
---reused, so a stale entry eventually names an unrelated buffer.
---@param bufnr? integer  a buffer being deleted, still valid at this point
local function _prune(bufnr)
    for i = #_entries, 1, -1 do
        local b = _entries[i].bufnr
        if b == bufnr or not vim.api.nvim_buf_is_valid(b) then
            table.remove(_entries, i)
        end
    end
end

---The buffer the window should hold: the highest-priority one, the newest of
---them when several share a priority.
---@return integer?  bufnr
local function _target()
    local best ---@type ndap.ui.Panel.Entry?
    for _, e in ipairs(_entries) do
        if not best or e.priority > best.priority
            or (e.priority == best.priority and e.seq > best.seq) then
            best = e
        end
    end
    return best and best.bufnr
end

---@param bufnr integer
---@return boolean  whether the buffer is one of ours
local function _is_registered(bufnr)
    for _, e in ipairs(_entries) do
        if e.bufnr == bufnr then return true end
    end
    return false
end

---Give the window back to the user, Like a quickfix window turned ordinary
local function _disown()
    local win = _win
    _win, _shown = nil, nil
    if win and vim.api.nvim_win_is_valid(win) then
        -- fixedwin may have moved the pin to the width (window moved to the side)
        if vim.wo[win][0].winfixwidth then
            _ratio = vim.api.nvim_win_get_width(win) / vim.o.columns
        elseif vim.wo[win][0].winfixheight then
            _ratio = vim.api.nvim_win_get_height(win) / vim.o.lines
        end
        _win_setlocal(win, "winfixheight", nil)
        _win_setlocal(win, "winfixwidth", nil)
        _win_setlocal(win, "spell", false)
    end
    if _fixed_group then
        vim.api.nvim_del_augroup_by_id(_fixed_group)
        _fixed_group = nil
    end
end

---The window while it is still ours: valid, and holding one of our buffers. The
---user switching it to a buffer of their own hands it over, so a later `open`
---splits a new one rather than taking theirs.
---@return integer?  the window, when open
local function _open_win()
    if not _win then return nil end
    if vim.api.nvim_win_is_valid(_win) then
        local bufnr = vim.api.nvim_win_get_buf(_win)
        if bufnr == _shown or _is_registered(bufnr) then
            _shown = bufnr
            return _win
        end
    end
    _disown()
    return nil
end

-- Notice the handover as it happens: waiting for the next call into this module
-- would leave fixedwin pinning the height of a window that is no longer ours.
vim.api.nvim_create_autocmd("BufWinEnter", {
    group    = _augroup,
    callback = function() _open_win() end,
})

---@param win   integer  the window, already checked to be ours
---@param bufnr integer
local function _display(win, bufnr)
    if _shown == bufnr then return end
    vim.api.nvim_win_set_buf(win, bufnr)
    _shown = bufnr
end

---Open the window (a no-op when already open) and show the target buffer.
---@param focus? boolean  leave the cursor in the window; default false
function M.open(focus)
    if not _enabled then return end
    _prune()
    local bufnr = _target()
    if not bufnr then return end
    local win = _open_win()
    if win then
        if focus then vim.api.nvim_set_current_win(win) end
        _display(win, bufnr)
        return
    end
    -- fixedwin owns the split, its height pinning and the resize/ratio tracking;
    -- we only swap in the run's buffer. Its on_delete fires on WinClosed, so
    -- closing by any route (ours, `:q`) records the height and drops the state.
    _win, _fixed_group = fixedwin.create_fixed_win(bufnr, {
        axis = "height", ratio = _ratio or config.panel_height_ratio,
        enter = focus or false,
        on_delete = function(ratio)
            _ratio       = ratio
            _closed_with = _shown
            _win, _shown = nil, nil
            _fixed_group = nil
            -- Only a deletion of the buffer just closed with reopens the window,
            -- and only on this tick; a `:q` a moment earlier must not.
            vim.schedule(function() _closed_with = nil end)
        end,
    })

    _win_setlocal(_win, "spell", false)

    _shown = nil
    _display(_win, bufnr)
end

---Close the window, keeping the registry: the next registered buffer (or an
---explicit `open`) brings it back at the height it was left at.
function M.close()
    local win = _open_win()
    if win then vim.api.nvim_win_close(win, true) end
    _win, _shown = nil, nil
end

function M.toggle()
    if _open_win() then M.close() else M.open(true) end
end

---Bring the window in line with the registry: show the highest-priority live
---buffer, or close once the run's last buffer is gone. A buffer's deletion takes
---the window with it, so `deleted` reopens it for the next buffer in line.
---@param deleted? integer  a buffer being deleted, to forget before deciding
function M.refresh(deleted)
    _prune(deleted)
    local reopen = deleted ~= nil and deleted == _closed_with
    _closed_with = nil
    local bufnr  = _target()
    local win    = _open_win()
    if not bufnr then
        M.close()
    elseif win then
        _display(win, bufnr)
    elseif reopen then
        M.open(false)
    end
end

---Register a buffer for display. It takes the window immediately when it
---outranks the current occupant, and the window opens on the first registration
---unless `panel_auto_open` is off.
---@param bufnr integer
---@param opts? ndap.AddBufOpts
function M.add(bufnr, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    opts        = opts or {}
    _seq        = _seq + 1
    local entry = { bufnr = bufnr, priority = opts.priority or 0, seq = _seq }

    -- Re-registering a buffer restates its rank rather than adding a second entry
    -- (and a second deletion autocmd) for the same buffer.
    local known = false
    for i, e in ipairs(_entries) do
        if e.bufnr == bufnr then
            _entries[i], known = entry, true
            break
        end
    end
    if not known then
        _entries[#_entries + 1] = entry
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            group    = _augroup,
            buffer   = bufnr,
            once     = true,
            callback = function() M.refresh(bufnr) end,
        })
    end

    if config.panel_auto_open then M.open(false) else M.refresh() end
end

---Register `bufnr` and show it in the window now, opening the window when
---closed, with whatever the registry ranks highest. The window returns to the
---ranked buffer at the next registration or refresh.
---@param bufnr integer
---@param opts? ndap.AddBufOpts
function M.show(bufnr, opts)
    if not _enabled then return end
    M.add(bufnr, opts)
    M.open(true)
    local win = _open_win()
    if win then _display(win, bufnr) end
end

---@return integer? winid  the window, when open
function M.winid()
    return _open_win()
end

---One window for all runs, so which run a buffer came from does not matter
---here: it ranks against every other run's buffers, and a run's identity and
---outcome have nowhere to show.
---@param _run ndap.runner.Run
---@param bufnr integer
---@param opts ndap.AddBufOpts
function M.add_buf(_run, bufnr, opts) M.add(bufnr, opts) end

---Mark this panel the one in play, so the window operations above act. Called
---from `setup`, which also hands it the runs.
function M.init() _enabled = true end

return M
