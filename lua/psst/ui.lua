---@module "psst.ui"
---Scratch buffer and floating window helpers shared by prompt and float.

local M = {}

---@class Psst.ui.EditorSpaceOpts
---@field horizontal_margin integer
---@field vertical_margin integer
---@field border_columns integer
---@field border_rows integer

---@param opts Psst.ui.EditorSpaceOpts
---@return { width: integer, height: integer }
function M.editor_space(opts)
    return {
        width = math.max(1, vim.o.columns - opts.horizontal_margin * 2 - opts.border_columns),
        height = math.max(
            1,
            vim.o.lines - vim.o.cmdheight - opts.vertical_margin * 2 - opts.border_rows
        ),
    }
end

---@param available integer
---@param min_size integer
---@param max_size integer
---@param ratio number
---@return integer
function M.responsive_size(available, min_size, max_size, ratio)
    local target = math.floor(available * ratio)
    return math.max(1, math.min(available, max_size, math.max(min_size, target)))
end

---@param total integer
---@param content_size integer
---@param border_size integer
---@return integer
function M.centered_offset(total, content_size, border_size)
    return math.max(0, math.floor((total - content_size - border_size) / 2))
end

---@class Psst.ui.ScratchBufOpts
---@field filetype string|nil
---@field lines string[]|nil
---@field modifiable boolean|nil

---@param opts Psst.ui.ScratchBufOpts|nil
---@return integer
function M.create_scratch_buf(opts)
    opts = opts or {}
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_option_value("buftype", "nofile", { buf = buf })
    vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
    vim.api.nvim_set_option_value("swapfile", false, { buf = buf })
    if opts.filetype then
        vim.api.nvim_set_option_value("filetype", opts.filetype, { buf = buf })
    end
    if opts.lines then vim.api.nvim_buf_set_lines(buf, 0, -1, false, opts.lines) end
    if opts.modifiable ~= nil then
        vim.api.nvim_set_option_value("modifiable", opts.modifiable, { buf = buf })
    end
    return buf
end

---@param win integer
---@param opts table<string, any>
function M.apply_win_options(win, opts)
    for name, value in pairs(opts) do
        vim.api.nvim_set_option_value(name, value, { win = win })
    end
end

---@param win integer
---@param buf integer
function M.close_win_buf(win, buf)
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
    if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
end

return M
