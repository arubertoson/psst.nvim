---@module "psst.collect.diagnostic"
local M = {}

local severity_names = {
    [vim.diagnostic.severity.ERROR] = "ERROR",
    [vim.diagnostic.severity.WARN] = "WARN",
    [vim.diagnostic.severity.INFO] = "INFO",
    [vim.diagnostic.severity.HINT] = "HINT",
}

---@param bufnr integer
---@param cursor [integer, integer]
---@return vim.Diagnostic|nil
local function diagnostic_at_cursor(bufnr, cursor)
    local lnum, col = unpack(cursor)

    -- convert cursor row (1-based) to diagnostic row (0-based)
    lnum = lnum - 1

    local diags = vim.diagnostic.get(bufnr, { lnum = lnum })
    if #diags == 0 then return nil end

    ---@type vim.Diagnostic
    local wanted
    for _, d in ipairs(diags) do
        local end_col = d.end_col or d.col
        if d.col <= col and col < end_col then
            wanted = d
            break
        end
    end

    wanted = wanted or diags[1]

    return wanted
end

---@param diag vim.Diagnostic
---@param inv Psst.InvocationState
---@return Psst.payload.ContextItem
local function construct_diagnostic_context_item(diag, inv)
    -- convert diagnostic row (0-based) to cursor row (1-based)
    local start_line = diag.lnum + 1
    local end_line = diag.end_lnum and diag.end_lnum + 1 or start_line
    local start_col = diag.col
    local end_col = diag.end_col or diag.col

    local text = {}
    table.insert(text, ("severity: %s"):format(severity_names[diag.severity]))
    table.insert(text, ("source: %s"):format(diag.source or "unknown"))
    table.insert(text, ("code: %s"):format(diag.code or "unknown"))
    table.insert(text, ("range: %d:%d-%d:%d"):format(start_line, start_col, end_line, end_col))
    table.insert(text, ("message: %s"):format(diag.message))

    return {
        kind = "diagnostic",
        path = inv.path ~= "" and inv.path or nil,
        filetype = inv.filetype,
        start_line = start_line,
        end_line = end_line,
        text = table.concat(text, "\n"),
    }
end

---@param inv Psst.InvocationState
---@return Psst.payload.ContextItem|nil
function M.collect(inv)
    local diag = diagnostic_at_cursor(inv.bufnr, inv.cursor)
    if not diag then return nil end

    return construct_diagnostic_context_item(diag, inv)
end

return M
