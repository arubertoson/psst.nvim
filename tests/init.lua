vim.cmd([[let &runtimepath.=','.getcwd()]])
pcall(vim.cmd, "packadd mini.nvim")
pcall(vim.cmd, "packadd nvim-treesitter")
pcall(vim.cmd, "packadd nvim-treesitter-textobjects")

vim.g.psst_test = true

if #vim.api.nvim_list_uis() == 0 then require("mini.test").setup() end
