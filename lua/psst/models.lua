---@module "psst.models"
---Discovers and selects models exposed by the configured Pi executable.

local M = {}

local config = require("psst.config")

---@class Psst.models.Model
---@field id string
---@field provider string
---@field name string

---@type Psst.models.Model[]|nil
local cached_models = nil
local cached_executable = nil
---@type table<integer, fun(models: Psst.models.Model[]|nil, err: string|nil)>
local waiters = {}
local generation = 0
local loading = false
local loading_executable = nil
local selected_model = nil

---@param output string
---@return Psst.models.Model[]
local function parse_models(output)
    local models = {}
    for line in output:gmatch("[^\r\n]+") do
        local provider, name = line:match("^%s*(%S+)%s+(%S+)")
        if provider and provider ~= "provider" then
            models[#models + 1] = {
                id = provider .. "/" .. name,
                provider = provider,
                name = name,
            }
        end
    end
    return models
end

---@param models Psst.models.Model[]|nil
---@param err string|nil
local function notify_waiters(models, err)
    local pending = waiters
    waiters = {}
    for _, callback in ipairs(pending) do
        callback(models, err)
    end
end

---@param refresh boolean
---@param callback fun(models: Psst.models.Model[]|nil, err: string|nil)
local function load(refresh, callback)
    local executable = config.get().executable
    if not refresh and cached_models and cached_executable == executable then
        callback(cached_models, nil)
        return
    end

    waiters[#waiters + 1] = callback
    if loading and not refresh and loading_executable == executable then return end

    generation = generation + 1
    local request_generation = generation
    loading = true
    loading_executable = executable
    local ok, err = pcall(
        vim.system,
        { executable, "--list-models" },
        { text = true },
        function(result)
            vim.schedule(function()
                if request_generation ~= generation then return end
                loading = false
                loading_executable = nil
                if result.code ~= 0 then
                    local err = (result.stderr or ""):match("[^\n]+") or "Model listing failed"
                    notify_waiters(nil, err)
                    return
                end
                cached_models = parse_models(result.stdout or "")
                cached_executable = executable
                notify_waiters(cached_models, nil)
            end)
        end
    )
    if not ok then
        loading = false
        loading_executable = nil
        if request_generation == generation then notify_waiters(nil, tostring(err)) end
    end
end

function M.preload()
    load(false, function() end)
end

---@return string|nil
function M.current() return selected_model or config.get().model end

function M.refresh()
    cached_models = nil
    load(true, function(_, err)
        if err then
            vim.notify("Psst: " .. err, vim.log.levels.ERROR)
        else
            vim.notify("Psst: model list refreshed", vim.log.levels.INFO)
        end
    end)
end

function M.pick()
    load(false, function(models, err)
        if err then
            vim.notify("Psst: " .. err, vim.log.levels.ERROR)
            return
        end
        if not models or #models == 0 then
            vim.notify("Psst: Pi did not report any models", vim.log.levels.WARN)
            return
        end

        vim.ui.select(models, {
            prompt = "Psst model",
            format_item = function(model)
                local current = M.current()
                local marker = current and current:match("^([^:]+)") == model.id and " *" or ""
                return model.id .. marker
            end,
        }, function(model)
            if not model then return end
            selected_model = model.id
            vim.notify("Psst model: " .. model.id, vim.log.levels.INFO)
        end)
    end)
end

return M
