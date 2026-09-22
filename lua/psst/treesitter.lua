---@module "psst.treesitter"
---Treesitter operations needed to collect context around an inquiry.

local M = {}

---@class Psst.treesitter.Iterator
---@field iter fun(...): integer?, TSNode?
---@field query vim.treesitter.Query

---@param bufnr integer
---@return Psst.treesitter.Iterator|nil
function M.iter_textobj_captures(bufnr)
    local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
    if not lang then return nil end

    local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if not ok_parser or not parser then return nil end

    local ok_parse, trees = pcall(parser.parse, parser)
    local tree = ok_parse and trees and trees[1] or nil
    local root = tree and tree:root() or nil
    if not root then return nil end

    local ok_query, query = pcall(vim.treesitter.query.get, lang, "textobjects")
    if not ok_query or not query then return nil end

    local start_row, _, end_row = root:range()
    return {
        iter = query:iter_captures(root, bufnr, start_row, end_row + 1),
        query = query,
    }
end

---@param bufnr integer
---@param row integer
---@param col integer
---@return TSNode|nil
function M.node_at(bufnr, row, col)
    local lang = vim.treesitter.language.get_lang(vim.bo[bufnr].filetype)
    if not lang then return nil end

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if not ok or not parser then return nil end

    local ok_parse, trees = pcall(parser.parse, parser)
    local tree = ok_parse and trees and trees[1] or nil
    local root = tree and tree:root() or nil
    if not root then return nil end

    return root:named_descendant_for_range(row, col, row, col)
end

return M
