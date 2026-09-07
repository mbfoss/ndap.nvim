---@brief The right-click PopUp entries ndap contributes, present only while a
---debug session is live. Added on the first session, removed with the last, so
---the stock menu is untouched when nothing is being debugged.

local manager = require("ndap.manager")
local config  = require("ndap.config").current

local M       = {}

-- `:menu` splits its name on spaces and dots, so both are escaped.
local _ITEM   = "PopUp.Debug\\ Inspect"

local _init_done
local _shown = false

local function _add()
    if _shown then return end
    _shown = true
    -- `mousemodel=popup_setpos` moves the cursor to the click before the menu
    -- opens, so the normal-mode entry inspects what was clicked. In visual mode
    -- the leading `:` supplies the `'<,'>` range `inspect` reads the selection from.
    -- Priority below the 500 every stock PopUp entry gets, so ours sorts first.
    vim.cmd(("silent! nnoremenu .100 %s <Cmd>Ndap inspect<CR>"):format(_ITEM))
    vim.cmd(("silent! vnoremenu .100 %s :Ndap inspect<CR>"):format(_ITEM))
end

local function _remove()
    if not _shown then return end
    _shown = false
    vim.cmd("silent! aunmenu " .. _ITEM)
end

---Wire the entries to session lifecycle. Idempotent; a no-op when the
---`popup_menu` config option is off.
function M.init()
    if _init_done or not config.popup_menu then return end
    _init_done = true

    manager.on_session_added:subscribe(_add)
    manager.on_session_removed:subscribe(function()
        if next(manager.sessions()) == nil then _remove() end
    end)
end

return M
