---@module "psst.collect.block"
---Collects a code block from the editor: visual selection when marked,
---otherwise treesitter outer block, otherwise surrounding lines.

local M = {}

local constants = require("psst.constants")
local ts = require("psst.treesitter")

---@param bufnr integer
---@param n_lines integer
---@param cursor [integer, integer]
---@param path string
---@param filetype string
---@return Psst.payload.ContextItem|nil
local function collect_surrounding(bufnr, n_lines, cursor, path, filetype)
    local total = vim.api.nvim_buf_line_count(bufnr)
    if total == 0 then return nil end

    local row = cursor[1]
    local start_line = math.max(1, row - n_lines)
    local end_line = math.min(total, row + n_lines)

    local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    if vim.tbl_isempty(lines) then return nil end

    local text = table.concat(lines, "\n")
    if text == "" then return nil end

    return {
        kind = "block",
        source = path ~= "",
        path = path ~= "" and path or nil,
        filetype = filetype,
        start_line = start_line,
        end_line = end_line,
        text = text,
    }
end

---@param bufnr integer
---@param selection Psst.Selection|nil
---@param path string
---@param filetype string
---@return Psst.payload.ContextItem|nil
local function collect_visual_selection(bufnr, selection, path, filetype)
    if not selection then return nil end

    local lines = vim.api.nvim_buf_get_text(
        bufnr,
        selection.start_row,
        selection.start_col,
        selection.end_row,
        selection.end_col,
        {}
    )
    if vim.tbl_isempty(lines) then return nil end

    local text = table.concat(lines, "\n")
    if text == "" then return nil end

    return {
        kind = "block",
        source = path ~= "",
        path = path ~= "" and path or nil,
        filetype = filetype,
        start_line = selection.start_row + 1,
        end_line = selection.end_row + 1,
        text = text,
    }
end

local ROOT_NODE_TYPES = {
    chunk = true,
    document = true,
    module = true,
    program = true,
    source_file = true,
    translation_unit = true,
}

local TEXTOBJECT_OUTER_CAPTURES = {
    ["function.outer"] = true,
    ["class.outer"] = true,
    ["block.outer"] = true,
}

---@param node TSNode
local function node_range(node)
    local start_row, start_col, end_row, end_col = node:range()
    local end_exclusive = end_row + (end_col > 0 and 1 or 0)
    return start_row, start_col, end_row, end_col, end_exclusive
end

---@param node TSNode
---@param row integer
---@param col integer
local function node_contains_position(node, row, col)
    local start_row, start_col, end_row, end_col = node:range()
    if row < start_row or row > end_row then return false end
    if row == start_row and col < start_col then return false end
    if row == end_row and col > end_col then return false end
    return true
end

---@param node TSNode
---@param max_lines integer
local function is_bounded_context_node(node, max_lines)
    if ROOT_NODE_TYPES[node:type()] then return false end
    local start_row, _, _, _, end_exclusive = node_range(node)
    local line_count = end_exclusive - start_row
    return line_count > 1 and line_count <= max_lines
end

---@param node TSNode
local function node_line_count(node)
    local start_row, _, _, _, end_exclusive = node_range(node)
    return end_exclusive - start_row
end

---@param bufnr integer
---@param node TSNode
---@param path string
---@param filetype string
local function context_item_from_node(bufnr, node, path, filetype)
    local start_row, _, _, _, end_exclusive = node_range(node)
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_exclusive, false)
    if vim.tbl_isempty(lines) then return nil end

    local text = table.concat(lines, "\n")
    if text == "" then return nil end

    return {
        kind = "block",
        source = path ~= "",
        path = path ~= "" and path or nil,
        filetype = filetype,
        start_line = start_row + 1,
        end_line = end_exclusive,
        text = text,
    }
end

---@param bufnr integer
---@param cursor [integer, integer]
---@param max_lines integer
local function find_textobject_outer_node(bufnr, cursor, max_lines)
    local row = cursor[1] - 1
    local col = cursor[2]
    local captures = ts.iter_textobj_captures(bufnr)
    if not captures then return nil end

    local best = nil
    for id, node in captures.iter do
        local name = captures.query.captures[id]
        if
            TEXTOBJECT_OUTER_CAPTURES[name]
            and node_contains_position(node, row, col)
            and is_bounded_context_node(node, max_lines)
            and (not best or node_line_count(node) < node_line_count(best))
        then
            best = node
        end
    end

    return best
end

---@param bufnr integer
---@param cursor [integer, integer]
---@param max_lines integer
local function find_bounded_ancestor_node(bufnr, cursor, max_lines)
    local node = ts.node_at(bufnr, cursor[1] - 1, cursor[2])
    while node do
        if node:named() and is_bounded_context_node(node, max_lines) then return node end
        node = node:parent()
    end
    return nil
end

---@param inv Psst.InvocationState
---@param surrounding_lines integer
local function collect_treesitter_outer(inv, surrounding_lines)
    local max_lines = surrounding_lines * 2 + 1
    local node = find_textobject_outer_node(inv.bufnr, inv.cursor, max_lines)
        or find_bounded_ancestor_node(inv.bufnr, inv.cursor, max_lines)
    return node and context_item_from_node(inv.bufnr, node, inv.path, inv.filetype) or nil
end

---@param inv Psst.InvocationState
---@return Psst.payload.ContextItem|nil
function M.collect(inv)
    local surrounding_lines = constants.DEFAULT_SURROUNDING_LINES

    local item = collect_visual_selection(inv.bufnr, inv.selection, inv.path, inv.filetype)
    if item then return item end

    item = collect_treesitter_outer(inv, surrounding_lines)
    if item then return item end

    return collect_surrounding(inv.bufnr, surrounding_lines, inv.cursor, inv.path, inv.filetype)
end

return M
