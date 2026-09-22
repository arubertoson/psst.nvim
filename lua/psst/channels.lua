---@module "psst.channels"
---Registry for agent delivery channels. `get` only resolves a destination
---to its channel module; validation and side effects happen in `channel.send`.

local M = {}

---@enum Psst.channels.Destination
M.DESTINATION = {
    FLOAT = "float",
    EDITOR = "editor",
}

---@class Psst.channels.Transport
---@field message string
---@field response Psst.Response|nil
---@field run fun(stdin: string, on_event: fun(event: table), on_exit: fun(result: vim.SystemCompleted)): vim.SystemObj|nil
---@field dispatch fun(event: table, handlers: Psst.adapters.Handlers)

---@class Psst.channels.Channel
---@field send fun(transport: Psst.channels.Transport, ctx: Psst.ConfigState): boolean

local CHANNELS = {
    [M.DESTINATION.FLOAT] = function() return require("psst.channels.float") end,
    [M.DESTINATION.EDITOR] = function() return require("psst.channels.editor") end,
}

---@param destination Psst.channels.Destination
---@return Psst.channels.Channel
function M.get(destination)
    local load = CHANNELS[destination]
    if not load then error("Missing channel for destination: " .. destination) end
    return load()
end

return M
