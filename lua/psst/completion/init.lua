---@module "psst.completion"
---Selects Blink providers for the current prompt token.

local M = {}

---@param bufnr integer
---@return string[]
function M.sources(bufnr)
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
    local ref = require("psst.reference").at_cursor(line, cursor[2])
    if ref and ref.selector then
        if ref.selector.kind == "symbol" then return { "prompt_symbol" } end
        return {}
    end
    return { "prompt_files" }
end

return M
