---Return the smallest positive integer absent from the input.
---@param values integer[]
---@return integer
local function first_missing_positive(values)
    local sorted = vim.deepcopy(values)
    table.sort(sorted)

    local candidate = 1
    for _, value in ipairs(sorted) do
        if value == candidate then
            candidate = candidate + 1
        elseif value > candidate then
            break
        end
    end

    return candidate
end

return first_missing_positive
