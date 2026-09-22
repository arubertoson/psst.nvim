---@module "psst.health"

local M = {}

function M.check()
    vim.health.start("psst.nvim")

    local config = require("psst.config").get()
    local executable = vim.fn.exepath(config.executable)
    if executable == "" then
        vim.health.error(
            ("Configured harness executable `%s` was not found in $PATH"):format(config.executable)
        )
    else
        vim.health.ok(("%s adapter executable: %s"):format(config.adapter, executable))
    end
end

return M
