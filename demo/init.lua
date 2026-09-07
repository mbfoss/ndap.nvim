-- Minimal init for the README recordings: only ndap, the debugpy adapter and
-- the demo source, so a GIF shows the plugin and nothing else.
local demo = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(demo .. "/..", ":p")

vim.opt.rtp:append(root) -- ndap.nvim itself
vim.opt.rtp:append(os.getenv("NDAP_ADAPTERS")
    or vim.fn.expand("~/.config/nvim/pack/plugins/opt/ndap-adapters.nvim"))
vim.opt.rtp:append(vim.fn.expand("~/.local/share/nvim/site")) -- python treesitter parser
vim.opt.rtp:append(vim.fn.expand("~/.config/nvim")) -- colors/pastelstone.lua

vim.o.number = true
vim.o.signcolumn = "yes"
vim.o.laststatus = 2
vim.o.showtabline = 2
vim.o.ruler = false
vim.o.showmode = false
vim.o.showcmd = false
vim.o.cmdheight = 1
vim.o.termguicolors = true
vim.o.background = "dark"
vim.o.scrolloff = 6
vim.o.updatetime = 100
vim.o.swapfile = false
vim.o.shadafile = "NONE"
vim.o.mouse = ""
vim.o.shortmess = vim.o.shortmess .. "I"
vim.o.statusline = " %f  %= %l/%L "

-- pastelstone is the maintainer's scheme; fall back when it is not installed.
if not pcall(vim.cmd.colorscheme, "pastelstone") then vim.cmd.colorscheme("habamax") end

require("ndap").setup({ debug_view_width_ratio = 0.3 })
require("nvim_demo").setup({ fg = "#2e2f33", bg = "#90b8e3", fill = "#3a3b41" })

-- The takes only read the source; a stray keystroke must not edit it.
vim.api.nvim_create_autocmd("FileType", {
    pattern = "python",
    callback = function(ev) vim.bo[ev.buf].modifiable = false end,
})
