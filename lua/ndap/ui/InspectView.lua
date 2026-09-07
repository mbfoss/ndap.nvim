---@brief Ephemeral inspect popup: evaluates an expression and shows its value as
---a lazily-expandable tree in a temporary floating window. Built on the same
---TreeBuffer as the DebugView, but throwaway: the buffer/window are wiped as
---soon as the float is left or dismissed.

local TreeBuffer  = require("ndap.util.TreeBuffer")
local value_hover = require("ndap.ui.value_hover")
local manager     = require("ndap.manager")
local format      = require("ndap.ui.format")
local ui_util     = require("ndap.util.ui")

local M = {}

---A tree node: the value hover's fields plus what the tree needs to expand it.
---@class ndap.ui.InspectView.NodeData : ndap.ui.value_hover.Value
---@field variablesReference number?
---@field is_root boolean?

---Render one value node: `name = value` (root) / `name: value` (child). Mirrors
---the DebugView variable/expression styling.
---@param data ndap.ui.InspectView.NodeData?
---@return string[][], string[][]
local function _format_node(data)
    if not data then return {}, {} end
    local chunks = {}
    chunks[#chunks + 1] = { data.name }
    chunks[#chunks + 1] = { data.is_root and " = " or ": ", "NonText" }
    chunks[#chunks + 1] = { format.oneline(data.value), "@string" }
    return chunks, {}
end

---Show a tree node's full value, once the inspect float is gone: the hover takes
---its place over whatever window is current, rather than stacking on it.
---@param data ndap.ui.InspectView.NodeData?
local function _show_value(data)
    if not data then return end
    value_hover.show(data, { focus_id = "ndap_inspect_value", focus = true })
end

---Open the inspect float for `expr`, evaluated in the active session. No-op with a
---warning when there is no session, nothing to inspect, or the evaluation fails.
---@param expr string
function M.open(expr)
    if not expr or expr == "" then
        vim.notify("[dap] nothing to inspect", vim.log.levels.WARN)
        return
    end
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN)
        return
    end

    -- Capture the inspected symbol's screen position *now*, before the async evaluate;
    -- the cursor may have moved by the time the response arrives. `screenpos` is
    -- 1-based ({row=0} off-screen); nvim_win_get_cursor's column needs shifting to 1.
    local cursor = vim.api.nvim_win_get_cursor(0)
    local anchor = vim.fn.screenpos(0, cursor[1], cursor[2] + 1)

    manager.evaluate(expr, "hover", function(body, err)
        if err or not body then
            vim.notify("[dap] " .. expr .. ": " .. (err or "not available"), vim.log.levels.WARN)
            return
        end

        local tree = TreeBuffer.new({
            filetype  = "ndap-inspect",
            formatter = function(_, data, _) return _format_node(data) end,
        })

        -- Track which nodes' children have already been fetched so re-expanding a
        -- collapsed node doesn't re-request.
        local loaded = {}

        local win ---@type integer?

        ---Resize the float to fit its current content, capped to 80% of the editor.
        local function fit()
            if not win or not vim.api.nvim_win_is_valid(win) then return end
            local buf = tree:get_bufnr()
            if buf <= 0 then return end
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local w = 20
            for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
            w = math.min(w + 1, math.floor(vim.o.columns * 0.8))
            local h = math.min(math.max(#lines, 1), math.floor(vim.o.lines * 0.8))
            pcall(vim.api.nvim_win_set_width, win, w)
            pcall(vim.api.nvim_win_set_height, win, h)
        end

        ---Fetch and attach the children of the node at `parent_id`.
        ---@param parent_id any
        ---@param ref number
        local function load_children(parent_id, ref)
            loaded[parent_id] = true
            local tmp = { variablesReference = ref }
            sess:fetch_variables(tmp, function()
                local children = {}
                for i, var in ipairs(tmp.variables or {}) do
                    local expandable = var.variablesReference and var.variablesReference > 0
                    children[#children + 1] = {
                        id         = parent_id .. "::" .. (var.name or i) .. "#" .. i,
                        expandable = expandable,
                        expanded   = false,
                        data       = {
                            name               = var.name or "?",
                            value              = var.value,
                            type               = var.type,
                            variablesReference = var.variablesReference,
                        },
                    }
                end
                tree:set_children(parent_id, children)
                fit()
            end)
        end

        tree:subscribe({
            on_toggle = function(id, data, expanded)
                if not expanded then
                    fit()
                    return
                end
                if data and data.variablesReference and data.variablesReference > 0 and not loaded[id] then
                    load_children(id, data.variablesReference)
                else
                    fit()
                end
            end,
        })

        local buf = tree:create_buffer(function() end)
        tree:add_item(nil, {
            id         = "0",
            expandable = body.variablesReference and body.variablesReference > 0 or false,
            expanded   = false,
            data       = {
                name               = expr,
                value              = body.result,
                type               = body.type,
                variablesReference = body.variablesReference,
                is_root            = true,
            },
        })

        local ui_w, ui_h = vim.o.columns, vim.o.lines
        local width = math.floor(ui_w * 0.4)
        ---@type vim.api.keyset.win_config
        local win_opts = {
            relative  = "editor",
            width     = width,
            height    = 1,
            style     = "minimal",
            border    = "rounded",
            title     = " " .. expr .. " ",
            title_pos = "center",
        }
        if anchor.row > 0 then
            -- Anchor just below/at the symbol (screenpos is 1-based; editor rows
            -- are 0-based), clamped so the float stays fully on screen. A 2-row
            -- border/height allowance keeps the initial 1-line float visible.
            win_opts.row = math.min(anchor.row, math.max(0, ui_h - 4))
            win_opts.col = math.min(math.max(0, anchor.col - 1), math.max(0, ui_w - width - 2))
        else
            win_opts.row = math.floor((ui_h - win_opts.height) / 2)
            win_opts.col = math.floor((ui_w - width) / 2)
        end

        local close
        win = ui_util.create_window(buf, true, win_opts, function() win = nil end)
        close = function()
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end

        local wo = vim.wo[win][0]
        wo.wrap = false
        wo.winfixbuf = true
        wo.winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle"

        -- The inspect float is a hover itself: dismiss it and put the value hover
        -- in its place, rather than stacking the two.
        vim.keymap.set("n", "K", function()
            local cur = tree:get_cursor_item()
            if not cur then return end
            local data = cur.data
            close()
            vim.schedule(function() _show_value(data) end)
        end, { buffer = buf, silent = true, desc = "Show full value" })

        vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
        vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
        vim.api.nvim_create_autocmd("WinLeave", {
            buffer = buf,
            once   = true,
            callback = close,
        })

        fit()
    end)
end

return M
