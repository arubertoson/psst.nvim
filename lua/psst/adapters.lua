---@module "psst.adapters"
---Resolves the configured coding-agent harness adapter.

local M = {}

---@class Psst.adapters.NoSessionTarget
---@field kind "none"

---@class Psst.adapters.ExplicitSessionTarget
---@field kind "explicit"
---@field id string

---@alias Psst.adapters.SessionTarget Psst.adapters.NoSessionTarget|Psst.adapters.ExplicitSessionTarget
---@alias Psst.adapters.Intent "inquire"|"generate"

---@class Psst.adapters.Handlers
---@field on_thinking fun(delta: string)|nil
---@field on_text fun(delta: string)|nil

---@class Psst.adapters.RunOpts
---@field config Psst.config.Config
---@field request Psst.Request
---@field target Psst.adapters.SessionTarget
---@field intent Psst.adapters.Intent
---@field stdin string
---@field cwd string
---@field on_event fun(event: table)
---@field on_exit fun(result: vim.SystemCompleted)

---@class Psst.Adapter
---@field run fun(opts: Psst.adapters.RunOpts): vim.SystemObj|nil
---@field dispatch fun(event: table, handlers: Psst.adapters.Handlers)

local ADAPTERS = {
    pi = require("psst.adapters.pi"),
}

---@param name string
---@return Psst.Adapter
function M.get(name)
    local adapter = ADAPTERS[name]
    if not adapter then error("Unknown psst adapter: " .. name) end
    return adapter
end

return M
