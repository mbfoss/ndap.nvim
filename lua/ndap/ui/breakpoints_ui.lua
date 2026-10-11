---@brief Singleton that renders breakpoints in source buffers.
---Subscribes to breakpoints.on_change and keeps the marks in sync.
---
---Line breakpoints are gutter signs. Column breakpoints render an inline glyph
---right before their column instead. Both drive the fileextmarks module directly
---(the signs module only ever places marks in the gutter at column 0).

local fileextmarks = require("ndap.util.fileextmarks")
local breakpoints  = require("ndap.dap.breakpoints")
local format       = require("ndap.ui.format")
local manager      = require("ndap.manager")

local M            = {}

---@type ndap.util.fileextmarks.GroupFunctions?
local _group
local _init_done

local _PRIORITY    = 10

local function _refresh()
    if not _group then return end
    _group.remove_extmarks()
    for _, bp in ipairs(breakpoints.all()) do
        if bp.source ~= "" then
            assert(bp.internal_id > 0, "breakpoint internal_id must be positive")
            -- While a session is live the adapter may bind the breakpoint to a
            -- different line; show the sign there. Falls back to the stored line
            -- when there is no session (st is nil) or it was not moved.
            local st    = manager.bp_status(bp.internal_id)
            local lnum  = (st and st.line) or bp.line
            local glyph, hl, name = format.breakpoint_symbol({
                kind          = "source",
                disabled      = bp.disabled,
                verified      = st and st.verified,
                condition     = bp.condition,
                hit_condition = bp.hit_condition,
                log_message   = bp.log_message,
            })
            ---@type vim.api.keyset.set_extmark
            local opts  = { priority = _PRIORITY }
            local col   = 0
            if bp.column then
                -- Column breakpoint: inline glyph just before the column only, no
                -- gutter sign. Show it where the adapter bound it, if it moved.
                local shown_col    = (st and st.column) or bp.column
                col                = math.max(0, shown_col - 1)
                opts.virt_text     = { { glyph, hl } }
                opts.virt_text_pos = "inline"
            else
                -- Line breakpoint: gutter sign.
                opts.sign_text     = glyph
                opts.sign_hl_group = hl
            end
            _group.set_file_extmark(bp.internal_id, bp.source, lnum, col, opts, { name = name })
        end
    end
end

---Feed the marks' current buffer positions back into the registry, so a
---breakpoint follows the edits that moved its line. Only a saved buffer may do
---this: a discarded edit never reached the file the stored line describes.
---@param bufnr integer
local function _relocate_from_buffer(bufnr)
    if not _group then return end
    if vim.bo[bufnr].modified then return end
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then return end

    local marks = _group.get_file_extmarks(file, true)
    if #marks == 0 then return end

    local positions = {}
    for _, mark in ipairs(marks) do
        positions[mark.id] = { lnum = mark.lnum, col = mark.col }
    end
    breakpoints.relocate_batch(positions)
end

function M.init()
    if _init_done then return end
    _init_done = true
    fileextmarks.init("ndap")
    _group     = fileextmarks.define_group("breakpoints")

    breakpoints.on_change:subscribe(_refresh)
    -- Adapter-verified status is session-scoped; repaint signs when it changes.
    manager.on_breakpoint_updated:subscribe(function() _refresh() end)
    manager.on_active_changed:subscribe(function() _refresh() end)

    local augroup = vim.api.nvim_create_augroup("ndap.breakpoints_ui", { clear = true })
    -- `BufWritePost` alone. Doing this on `BufUnload` too moved a breakpoint by
    -- edits the user then threw away: closing the buffer unsaved wrote the live
    -- position into the registry, and reopening the file showed it there.
    vim.api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        callback = function(ev) _relocate_from_buffer(ev.buf) end,
        desc = "ndap: follow breakpoint marks moved by edits",
    })

    _refresh()
end

return M
