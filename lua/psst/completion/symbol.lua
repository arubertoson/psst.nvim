---@module "psst.completion.symbol"
---Blink source for Treesitter symbols in an Inline Reference target.

local M = {}

function M.new(opts)
    opts = opts or {}
    return setmetatable({ opts = opts }, { __index = M })
end

function M:get_trigger_characters() return { "#" } end

function M:get_completions(completion_context, callback)
    local ref =
        require("psst.reference").at_cursor(completion_context.line, completion_context.cursor[2])
    if not ref or not ref.selector or ref.selector.kind ~= "symbol" or ref.invalid then
        callback({ items = {}, is_incomplete_forward = false, is_incomplete_backward = false })
        return
    end

    local cwd = self.opts.get_cwd(completion_context)
    local invocation_buf = self.opts.get_invocation_buf(completion_context)
    local symbols = require("psst.context").symbol_candidates(ref, cwd, invocation_buf)
    local hash = assert(ref.raw:find("#", 1, true))
    local start_col = ref.span.start_col + hash
    local end_col = completion_context.cursor[2]
    local line = completion_context.cursor[1] - 1
    local items = {}
    for _, symbol in ipairs(symbols) do
        items[#items + 1] = {
            label = symbol.name,
            kind = vim.lsp.protocol.CompletionItemKind[symbol.kind]
                or vim.lsp.protocol.CompletionItemKind.Text,
            detail = ("%s   %d-%d"):format(symbol.kind, symbol.start_line, symbol.end_line),
            labelDetails = {
                description = ("%s %d-%d"):format(symbol.kind, symbol.start_line, symbol.end_line),
            },
            textEdit = {
                newText = symbol.name,
                range = {
                    start = { line = line, character = start_col },
                    ["end"] = { line = line, character = end_col },
                },
            },
        }
    end
    callback({
        items = items,
        is_incomplete_forward = false,
        is_incomplete_backward = false,
    })
end

return M
