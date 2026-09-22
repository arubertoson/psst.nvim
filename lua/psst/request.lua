---@module "psst.request"
---Validates requests at the public agent boundary.

local M = {}

local channels = require("psst.channels")
local collect = require("psst.collect")

local REQUEST_KEYS = {
    destination = true,
    force_new_session = true,
    collect = true,
    prompt = true,
    preset = true,
    context = true,
}

local CONTEXT_KEYS = {
    kind = true,
    source = true,
    path = true,
    filetype = true,
    start_line = true,
    end_line = true,
    symbol = true,
    whole_file = true,
    text = true,
}

local DESTINATIONS = {
    [channels.DESTINATION.FLOAT] = true,
    [channels.DESTINATION.EDITOR] = true,
}

local COLLECTORS = {
    [collect.COLLECT.BLOCK] = true,
    [collect.COLLECT.DIAGNOSTIC] = true,
}

---@param value table
---@param allowed table<string, boolean>
---@param name string
local function validate_keys(value, allowed, name)
    for key in pairs(value) do
        if not allowed[key] then error(("unknown %s field: %s"):format(name, tostring(key))) end
    end
end

---@param value any
---@param name string
local function validate_optional_string(value, name)
    if value ~= nil and type(value) ~= "string" then error(name .. " must be a string") end
end

---@param item any
---@param index integer
local function validate_context_item(item, index)
    local name = ("agent context item %d"):format(index)
    if type(item) ~= "table" then error(name .. " must be a table") end
    validate_keys(item, CONTEXT_KEYS, name)
    if type(item.kind) ~= "string" or item.kind == "" then
        error(name .. ".kind must be a non-empty string")
    end
    if type(item.text) ~= "string" then error(name .. ".text must be a string") end

    for _, field in ipairs({ "path", "filetype", "symbol" }) do
        validate_optional_string(item[field], name .. "." .. field)
    end
    for _, field in ipairs({ "source", "whole_file" }) do
        if item[field] ~= nil and type(item[field]) ~= "boolean" then
            error(name .. "." .. field .. " must be a boolean")
        end
    end
    for _, field in ipairs({ "start_line", "end_line" }) do
        local value = item[field]
        if value ~= nil and (type(value) ~= "number" or value < 1 or value % 1 ~= 0) then
            error(name .. "." .. field .. " must be a positive integer")
        end
    end
end

---@param request any
function M.validate(request)
    if type(request) ~= "table" then error("agent request must be a table") end
    validate_keys(request, REQUEST_KEYS, "agent request")
    if not DESTINATIONS[request.destination] then error("invalid agent destination") end
    if request.force_new_session ~= nil and type(request.force_new_session) ~= "boolean" then
        error("agent force_new_session must be a boolean")
    end
    validate_optional_string(request.prompt, "agent prompt")
    validate_optional_string(request.preset, "agent preset")

    if request.collect ~= nil then
        if type(request.collect) ~= "table" or not vim.islist(request.collect) then
            error("agent collect must be a list")
        end
        for index, collector in ipairs(request.collect) do
            if not COLLECTORS[collector] then
                error(
                    ("unknown agent collector at index %d: %s"):format(index, tostring(collector))
                )
            end
        end
    end

    if request.context ~= nil then
        if type(request.context) ~= "table" or not vim.islist(request.context) then
            error("agent context must be a list")
        end
        for index, item in ipairs(request.context) do
            validate_context_item(item, index)
        end
    end
end

return M
