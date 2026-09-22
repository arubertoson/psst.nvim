---@module "psst.lines"
---Helpers for accumulating newline-delimited streamed text.

local M = {}

---Splits a streamed delta into complete lines and an incomplete tail.
---@param pending string|nil
---@param delta string
---@return string[] complete
---@return string pending_tail
function M.split_pending(pending, delta)
    local combined = (pending or "") .. delta
    local parts = vim.split(combined, "\n", { plain = true })
    return vim.list_slice(parts, 1, #parts - 1), parts[#parts] or ""
end

---Appends a streamed delta to an accumulator table with `lines` and `pending` fields.
---@param acc { lines: string[], pending: string }
---@param delta string
---@return nil
function M.push(acc, delta)
    local complete, pending = M.split_pending(acc.pending, delta)
    vim.list_extend(acc.lines, complete)
    acc.pending = pending
end

---Flushes a non-empty pending tail into the accumulator's complete lines.
---@param acc { lines: string[], pending: string }
---@return string[]
function M.flush(acc)
    if acc.pending ~= "" then
        table.insert(acc.lines, acc.pending)
        acc.pending = ""
    end
    return acc.lines
end

return M
