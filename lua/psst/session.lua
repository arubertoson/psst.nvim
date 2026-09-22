---@module "psst.session"
---Owns the in-memory Agent Session and Response history.

local M = {}

---@class Psst.Session
---@field id string
---@field cwd string
---@field responses Psst.Response[]
---@field response_index integer

---@class Psst.Response
---@field lines string[]
---@field label string
---@field status "streaming"|"complete"|"error"

---@class Psst.SessionHistory
---@field sessions Psst.Session[]
---@field session_index integer

---@class Psst.session.InactiveState
---@field kind "inactive"

---@class Psst.session.ActiveState
---@field kind "active"
---@field history Psst.SessionHistory

---@alias Psst.session.State Psst.session.InactiveState|Psst.session.ActiveState

---@class Psst.session.Selection
---@field session Psst.Session
---@field response Psst.Response
---@field session_index integer
---@field session_count integer
---@field response_index integer
---@field response_count integer

---@type Psst.session.State
local _state = { kind = "inactive" }

local function new_session_id()
    local bytes, err = vim.uv.random(16)
    if not bytes then error("Failed to generate agent session ID: " .. tostring(err)) end

    local values = { bytes:byte(1, 16) }
    values[7] = bit.bor(bit.band(values[7], 0x0f), 0x40)
    values[9] = bit.bor(bit.band(values[9], 0x3f), 0x80)

    return ("%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x"):format(
        unpack(values)
    )
end

---@return Psst.SessionHistory|nil
local function history()
    if _state.kind == "inactive" then return nil end
    return _state.history
end

---@return Psst.Response|nil
local function streaming_response()
    local value = history()
    if not value then return nil end

    for _, agent_session in ipairs(value.sessions) do
        for _, response in ipairs(agent_session.responses) do
            if response.status == "streaming" then return response end
        end
    end
    return nil
end

---@param cwd string
---@param label string
---@return Psst.Session
---@return Psst.Response
local function create_session(cwd, label)
    local response = {
        lines = { "" },
        label = label,
        status = "streaming",
    }
    local agent_session = {
        id = new_session_id(),
        cwd = cwd,
        responses = { response },
        response_index = 1,
    }

    local value = history()
    if value then
        value.sessions[#value.sessions + 1] = agent_session
        value.session_index = #value.sessions
    else
        _state = {
            kind = "active",
            history = {
                sessions = { agent_session },
                session_index = 1,
            },
        }
    end

    return agent_session, response
end

---@param cwd string
---@param label string
---@param force_new boolean
---@return Psst.Session
---@return Psst.Response
function M.begin_read(cwd, label, force_new)
    if streaming_response() then error("An agent response is already streaming") end

    local value = history()
    local selected = value and value.sessions[value.session_index] or nil
    if force_new or not selected or selected.cwd ~= cwd then return create_session(cwd, label) end

    local response = {
        lines = { "" },
        label = label,
        status = "streaming",
    }
    selected.responses[#selected.responses + 1] = response
    selected.response_index = #selected.responses
    return selected, response
end

---@param response Psst.Response
---@param status "complete"|"error"
function M.finish(response, status)
    if response ~= streaming_response() then
        error("Cannot finish a response that is not the active stream")
    end
    response.status = status
end

---@return Psst.session.Selection|nil
function M.selection()
    local value = history()
    if not value then return nil end

    local agent_session = value.sessions[value.session_index]
    local response = agent_session.responses[agent_session.response_index]
    return {
        session = agent_session,
        response = response,
        session_index = value.session_index,
        session_count = #value.sessions,
        response_index = agent_session.response_index,
        response_count = #agent_session.responses,
    }
end

---@param cwd string
---@return boolean
---@return integer|nil
function M.can_continue(cwd)
    local selected = M.selection()
    if not selected or selected.session.cwd ~= cwd then return false, nil end
    return true, selected.session_index
end

---@return boolean
function M.is_streaming() return streaming_response() ~= nil end

---@param response Psst.Response
---@return boolean
function M.is_selected(response)
    local selected = M.selection()
    return selected ~= nil and selected.response == response
end

---@param delta integer
---@return boolean
function M.navigate_response(delta)
    local value = history()
    if not value then return false end

    local agent_session = value.sessions[value.session_index]
    local target = agent_session.response_index + delta
    if target < 1 or target > #agent_session.responses then return false end

    agent_session.response_index = target
    return true
end

---@param delta integer
---@return boolean
function M.navigate_session(delta)
    local value = history()
    if not value then return false end

    local target = value.session_index + delta
    if target < 1 or target > #value.sessions then return false end

    value.session_index = target
    return true
end

---@return integer sessions
---@return integer responses
function M.counts()
    local value = history()
    if not value then return 0, 0 end

    local responses = 0
    for _, agent_session in ipairs(value.sessions) do
        responses = responses + #agent_session.responses
    end
    return #value.sessions, responses
end

function M.clear()
    if streaming_response() then
        error("Cannot clear agent sessions while a response is streaming")
    end
    _state = { kind = "inactive" }
end

return M
