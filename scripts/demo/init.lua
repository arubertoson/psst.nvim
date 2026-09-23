local source = assert(debug.getinfo(1, "S").source):gsub("^@", "")
local init_path = vim.fn.fnamemodify(source, ":p")
local root = vim.fn.fnamemodify(init_path, ":h:h:h")
local session_dir = vim.fn.tempname() .. "-psst-demo-sessions"

vim.opt.runtimepath:prepend(root)
vim.cmd.cd(vim.fn.fnameescape(root))

vim.g.mapleader = ","
vim.opt.background = "dark"
vim.opt.cmdheight = 1
vim.opt.cursorline = true
vim.opt.laststatus = 2
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.ruler = false
vim.opt.showmode = false
vim.opt.signcolumn = "no"
vim.opt.swapfile = false
vim.opt.termguicolors = true
vim.opt.wrap = false

pcall(vim.cmd.colorscheme, "habamax")

require("psst").setup({
    executable = vim.fs.joinpath(root, "scripts", "demo", "fake-pi.py"),
    session_dir = session_dir,
    float = { width = 54 },
})

vim.keymap.set(
    "n",
    "<leader>p",
    function() require("psst").prompt() end,
    { desc = "Demo: ask about this code" }
)

vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function() pcall(vim.fs.rm, session_dir, { recursive = true }) end,
})
