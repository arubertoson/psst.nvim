---@module "psst.collect"
---Resolves named context collectors into payload items.

local M = {}

---@enum Psst.collect.Type
M.COLLECT = {
    BLOCK = "block",
    DIAGNOSTIC = "diagnostic",
}

local providers = {
    [M.COLLECT.BLOCK] = require("psst.collect.block"),
    [M.COLLECT.DIAGNOSTIC] = require("psst.collect.diagnostic"),
}

---@param invocation Psst.InvocationState
---@param names Psst.collect.Type[]
---@return Psst.payload.ContextItem[]
function M.resolve(invocation, names)
    ---@type Psst.payload.ContextItem[]
    local items = {}
    for _, name in ipairs(names) do
        local provider = providers[name]
        if not provider then error("Unknown collect provider: " .. tostring(name)) end
        local item = provider.collect(invocation)
        if item then table.insert(items, item) end
    end

    return items
end

return M
