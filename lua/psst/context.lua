---@module "psst.context"
---Resolves Inline References and composes their Context Items with invocation
---and collector context.

local M = {}

local reference_parser = require("psst.reference")

---@class Psst.context.Symbol
---@field name string
---@field kind string
---@field start_line integer
---@field end_line integer

---@class Psst.context.ResolveResult
---@field references Psst.reference.Reference[]
---@field context Psst.payload.ContextItem[]
---@field blocking Psst.reference.Reference[]

---@class Psst.context.BuildResult: Psst.context.ResolveResult

---@class Psst.context.BuildOpts
---@field prompt string
---@field cwd string
---@field invocation Psst.InvocationState
---@field collect Psst.collect.Type[]

---@class Psst.context.BufferSource
---@field bufnr integer
---@field path string
---@field filetype string
---@field line_count integer

---@class Psst.context.ResolvedReference
---@field source Psst.context.BufferSource
---@field start_line integer
---@field end_line integer
---@field whole_file boolean|nil
---@field symbol string|nil

---@class Psst.context.SymbolCacheEntry
---@field changedtick integer
---@field language string
---@field path string
---@field symbols Psst.context.Symbol[]

---@type table<integer, Psst.context.SymbolCacheEntry>
local symbol_cache = {}

local SYMBOL_CAPTURES = {
    ["local.definition.function"] = {
        kind = "Function",
        outer = "function.outer",
        priority = 1,
    },
    ["local.definition.method"] = { kind = "Method", outer = "function.outer", priority = 2 },
    ["local.definition.type"] = { kind = "Class", outer = "class.outer", priority = 1 },
    ["local.definition.enum"] = { kind = "Enum", outer = "class.outer", priority = 2 },
    ["local.definition.namespace"] = { kind = "Module", outer = "class.outer", priority = 1 },
    ["local.definition.macro"] = { kind = "Function", outer = "function.outer", priority = 1 },
}

---@param path string
local function normalized(path) return vim.fs.normalize(vim.fn.fnamemodify(path, ":p")) end

---@param path string
---@param cwd string
local function absolute_path(path, cwd)
    if path == "" then return nil end
    if path:sub(1, 1) == "/" or path:match("^%a:[/\\]") then return normalized(path) end
    return normalized(vim.fs.joinpath(cwd, path))
end

---@param path string
---@return integer|nil
local function loaded_buffer(path)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            local name = vim.api.nvim_buf_get_name(bufnr)
            if name ~= "" and normalized(name) == path then return bufnr end
        end
    end
    return nil
end

---@param path string
---@return Psst.context.BufferSource|nil, string|nil
local function acquire_buffer(path)
    local bufnr = loaded_buffer(path)
    if not bufnr then
        local stat = vim.uv.fs_stat(path)
        if not stat then return nil, "file does not exist" end
        if stat.type ~= "file" then return nil, "path is not a file" end

        bufnr = vim.fn.bufadd(path)
        vim.fn.bufload(bufnr)
        if not vim.api.nvim_buf_is_loaded(bufnr) then
            error("Failed to load referenced file: " .. path)
        end
    end

    if not vim.api.nvim_buf_is_valid(bufnr) then
        error("Referenced buffer became invalid: " .. path)
    end

    return {
        bufnr = bufnr,
        path = path,
        filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr }),
        line_count = vim.api.nvim_buf_line_count(bufnr),
    },
        nil
end

---@param source Psst.context.BufferSource
---@param start_line integer
---@param end_line integer
local function source_text(source, start_line, end_line)
    return table.concat(
        vim.api.nvim_buf_get_lines(source.bufnr, start_line - 1, end_line, false),
        "\n"
    )
end

---@param left_row integer
---@param left_col integer
---@param right_row integer
---@param right_col integer
local function position_lte(left_row, left_col, right_row, right_col)
    return left_row < right_row or (left_row == right_row and left_col <= right_col)
end

---@param outer TSNode
---@param inner TSNode
local function contains(outer, inner)
    local outer_start_row, outer_start_col, outer_end_row, outer_end_col = outer:range()
    local inner_start_row, inner_start_col, inner_end_row, inner_end_col = inner:range()
    return position_lte(outer_start_row, outer_start_col, inner_start_row, inner_start_col)
        and position_lte(inner_end_row, inner_end_col, outer_end_row, outer_end_col)
end

---@param query vim.treesitter.Query
---@param root TSNode
---@param bufnr integer
---@return table<string, TSNode[]>
local function outer_nodes(query, root, bufnr)
    local result = { ["function.outer"] = {}, ["class.outer"] = {} }
    for id, node in query:iter_captures(root, bufnr, 0, -1) do
        local nodes = result[query.captures[id]]
        if nodes then nodes[#nodes + 1] = node end
    end
    return result
end

---@param candidates TSNode[]
---@param definition TSNode
---@return TSNode|nil
local function enclosing_outer(candidates, definition)
    local best
    for _, candidate in ipairs(candidates) do
        if contains(candidate, definition) and (not best or contains(best, candidate)) then
            best = candidate
        end
    end
    return best
end

---@param node TSNode
---@return integer, integer
local function node_lines(node)
    local start_row, _, end_row, end_col = node:range()
    return start_row + 1, end_row + (end_col > 0 and 1 or 0)
end

---@param match table<integer, TSNode[]>
---@param query vim.treesitter.Query
---@param definition TSNode
---@param bufnr integer
---@return string
local function symbol_name(match, query, definition, bufnr)
    local associated = {}
    for id, nodes in pairs(match) do
        if query.captures[id] == "local.definition.associated" then
            vim.list_extend(associated, nodes)
        end
    end
    if #associated == 0 then return vim.treesitter.get_node_text(definition, bufnr) end

    table.sort(associated, function(left, right)
        local left_row, left_col = left:start()
        local right_row, right_col = right:start()
        return left_row < right_row or (left_row == right_row and left_col < right_col)
    end)
    local start_row, start_col = associated[1]:start()
    local end_row, end_col = definition:end_()
    return table.concat(
        vim.api.nvim_buf_get_text(bufnr, start_row, start_col, end_row, end_col, {}),
        "\n"
    )
end

---@param source Psst.context.BufferSource
---@return Psst.context.Symbol[]
function M.symbols(source)
    local lang = vim.treesitter.language.get_lang(source.filetype)
    if not lang then return {} end

    local changedtick = vim.api.nvim_buf_get_changedtick(source.bufnr)
    local cached = symbol_cache[source.bufnr]
    if
        cached
        and cached.changedtick == changedtick
        and cached.language == lang
        and cached.path == source.path
    then
        return cached.symbols
    end

    local ok_parser, parser = pcall(vim.treesitter.get_parser, source.bufnr, lang)
    if not ok_parser or not parser then return {} end
    local ok_parse, trees = pcall(parser.parse, parser)
    local root = ok_parse and trees and trees[1] and trees[1]:root() or nil
    if not root then return {} end

    local ok_locals, locals_query = pcall(vim.treesitter.query.get, lang, "locals")
    local ok_textobjects, textobjects_query = pcall(vim.treesitter.query.get, lang, "textobjects")
    if not ok_locals or not locals_query or not ok_textobjects or not textobjects_query then
        return {}
    end

    local outers = outer_nodes(textobjects_query, root, source.bufnr)
    local symbols = {}
    ---@type table<string, { symbol: Psst.context.Symbol, priority: integer }>
    local seen = {}
    for _, match in locals_query:iter_matches(root, source.bufnr, 0, -1, { all = true }) do
        for id, nodes in pairs(match) do
            local capture = locals_query.captures[id]
            local spec = SYMBOL_CAPTURES[capture]
            if spec then
                for _, definition in ipairs(nodes) do
                    local outer = enclosing_outer(outers[spec.outer], definition)
                    if outer then
                        local name = symbol_name(match, locals_query, definition, source.bufnr)
                        local start_line, end_line = node_lines(outer)
                        local key = table.concat({ name, start_line, end_line }, "\0")
                        local existing = seen[key]
                        if existing then
                            if spec.priority > existing.priority then
                                existing.symbol.kind = spec.kind
                                existing.priority = spec.priority
                            end
                        else
                            local symbol = {
                                name = name,
                                kind = spec.kind,
                                start_line = start_line,
                                end_line = end_line,
                            }
                            seen[key] = { symbol = symbol, priority = spec.priority }
                            symbols[#symbols + 1] = symbol
                        end
                    end
                end
            end
        end
    end

    table.sort(symbols, function(left, right)
        if left.start_line == right.start_line then return left.name < right.name end
        return left.start_line < right.start_line
    end)
    symbol_cache[source.bufnr] = {
        changedtick = changedtick,
        language = lang,
        path = source.path,
        symbols = symbols,
    }
    return symbols
end

---@param ref Psst.reference.Reference
---@param cwd string
---@param invocation_buf integer
---@return Psst.context.BufferSource|nil, string|nil
local function reference_source(ref, cwd, invocation_buf)
    if not ref.path and ref.selector and ref.selector.kind == "symbol" then
        if not vim.api.nvim_buf_is_valid(invocation_buf) then
            return nil, "invocation buffer is no longer valid"
        end
        local path = vim.api.nvim_buf_get_name(invocation_buf)
        if path == "" then return nil, "invocation buffer has no file path" end
        return acquire_buffer(normalized(path))
    end

    local path = ref.path and absolute_path(ref.path, cwd) or nil
    if not path then return nil, "reference has no file path" end
    return acquire_buffer(path)
end

---@param ref Psst.reference.Reference
---@param cwd string
---@param invocation_buf integer
---@return Psst.context.ResolvedReference|nil, string|nil
local function resolve_reference(ref, cwd, invocation_buf)
    if ref.invalid then return nil, ref.error or "invalid reference" end
    if ref.incomplete then return nil, "incomplete reference" end

    local source, source_error = reference_source(ref, cwd, invocation_buf)
    if not source then return nil, source_error end

    local selector = ref.selector
    if not selector then
        return {
            source = source,
            start_line = 1,
            end_line = source.line_count,
            whole_file = true,
        },
            nil
    end

    if selector.kind == "lines" then
        local start_line = selector.start_line
        local end_line = selector.end_line
        if not start_line or not end_line then return nil, "incomplete line range" end
        if start_line < 1 or end_line < 1 then return nil, "line numbers must be positive" end
        if start_line > end_line then return nil, "line range is reversed" end
        if end_line > source.line_count then return nil, "line range is outside the file" end

        return {
            source = source,
            start_line = start_line,
            end_line = end_line,
        },
            nil
    end

    local matches = {}
    for _, symbol in ipairs(M.symbols(source)) do
        if symbol.name == selector.name then matches[#matches + 1] = symbol end
    end
    if #matches == 0 then return nil, "symbol does not exist" end
    if #matches > 1 then return nil, "symbol is ambiguous" end

    local symbol = matches[1]
    return {
        source = source,
        symbol = symbol.name,
        start_line = symbol.start_line,
        end_line = symbol.end_line,
    },
        nil
end

---@param resolved Psst.context.ResolvedReference
---@return Psst.payload.ContextItem
local function materialize_reference(resolved)
    return {
        kind = "file",
        source = true,
        path = resolved.source.path,
        filetype = resolved.source.filetype,
        symbol = resolved.symbol,
        start_line = resolved.start_line,
        end_line = resolved.end_line,
        whole_file = resolved.whole_file,
        text = source_text(resolved.source, resolved.start_line, resolved.end_line),
    }
end

---@param text string
---@param cursor [integer, integer]|nil
---@return Psst.reference.Reference[]
function M.parse(text, cursor) return reference_parser.parse(text, cursor) end

---@param references Psst.reference.Reference[]
---@param cursor [integer, integer]|nil
---@param text string
---@return boolean changed
function M.update_cursor(references, cursor, text)
    return reference_parser.update_cursor(references, cursor, text)
end

---@param references Psst.reference.Reference[]
---@param cwd string
---@param invocation_buf integer
function M.validate(references, cwd, invocation_buf)
    for _, ref in ipairs(references) do
        if not ref.invalid and not ref.incomplete then
            local _, resolution_error = resolve_reference(ref, cwd, invocation_buf)
            reference_parser.classify(ref, resolution_error)
        end
    end
end

---@param text string
---@param cursor [integer, integer]|nil
---@param cwd string
---@param invocation_buf integer
---@return Psst.context.ResolveResult
function M.resolve(text, cursor, cwd, invocation_buf)
    local references = M.parse(text, cursor)
    local context = {}
    local blocking = {}
    for _, ref in ipairs(references) do
        local resolved
        if not ref.invalid and not ref.incomplete then
            local resolution_error
            resolved, resolution_error = resolve_reference(ref, cwd, invocation_buf)
            reference_parser.classify(ref, resolution_error)
        end

        if resolved then
            context[#context + 1] = materialize_reference(resolved)
        else
            blocking[#blocking + 1] = ref
        end
    end
    return {
        references = references,
        context = context,
        blocking = blocking,
    }
end

---@param items Psst.payload.ContextItem[]
---@return Psst.payload.ContextItem[]
function M.compose(items)
    local whole_paths = {}
    for _, item in ipairs(items) do
        if item.source and item.path and item.whole_file then
            whole_paths[normalized(item.path)] = true
        end
    end

    local composed = {}
    local seen = {}
    for _, item in ipairs(items) do
        local key
        local covered_by_whole = false
        if item.source and item.path then
            local path = normalized(item.path)
            if item.whole_file then
                key = table.concat({ path, "whole" }, "\0")
            elseif item.start_line and item.end_line then
                covered_by_whole = whole_paths[path] == true
                key = table.concat({ path, item.start_line, item.end_line }, "\0")
            end
        end
        if not covered_by_whole and (not key or not seen[key]) then
            if key then seen[key] = true end
            composed[#composed + 1] = item
        end
    end
    return composed
end

---@param opts Psst.context.BuildOpts
---@return Psst.context.BuildResult
function M.build(opts)
    local resolved = M.resolve(opts.prompt, nil, opts.cwd, opts.invocation.bufnr)
    local items = require("psst.collect").resolve(opts.invocation, opts.collect)
    vim.list_extend(items, resolved.context)
    return {
        references = resolved.references,
        context = M.compose(items),
        blocking = resolved.blocking,
    }
end

---@param ref Psst.reference.Reference
---@param cwd string
---@param invocation_buf integer
---@return Psst.context.Symbol[]
function M.symbol_candidates(ref, cwd, invocation_buf)
    local source = reference_source(ref, cwd, invocation_buf)
    if not source then return {} end
    return M.symbols(source)
end

return M
