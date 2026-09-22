---@module "psst.progress"
---Shared spinner and thinking-phrase state for agent streaming UIs.

local M = {}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local THINKING_PHRASES = {
    "thinking about clouds",
    "consulting the void",
    "pondering existence",
    "chasing loose thoughts",
    "shuffling mental cards",
    "staring into the abyss",
    "rearranging neurons",
    "negotiating with logic",
    "counting invisible sheep",
    "asking the oracle",
    "untangling spaghetti",
    "summoning inspiration",
    "dreaming of semicolons",
    "interrogating the stack",
    "befriending the compiler",
}

local THINKING_PHRASE_UPDATE_MS = 1200
local SPINNER_INTERVAL_MS = 80

---@class Psst.progress.State
---@field spinner_timer uv.uv_timer_t?
---@field spinner_frame integer
---@field phrase string
---@field last_phrase_update integer

---Initializes progress fields on an existing state table.
---@param state Psst.progress.State
---@return nil
function M.init(state)
    state.spinner_timer = nil
    state.spinner_frame = 1
    state.phrase = THINKING_PHRASES[1]
    state.last_phrase_update = vim.uv.now()
end

---Returns the current spinner frame text.
---@param state Psst.progress.State
---@return string
function M.frame(state) return SPINNER_FRAMES[state.spinner_frame] end

---Advances to the next whimsical thinking phrase.
---@param phrase string
---@return string
local function next_thinking_phrase(phrase)
    local idx = 0
    for i, candidate in ipairs(THINKING_PHRASES) do
        if candidate == phrase then
            idx = i
            break
        end
    end
    return THINKING_PHRASES[(idx % #THINKING_PHRASES) + 1]
end

---Updates the thinking phrase when the throttle interval has elapsed.
---@param state Psst.progress.State
---@return boolean
function M.update_phrase(state)
    local now = vim.uv.now()
    if now - state.last_phrase_update < THINKING_PHRASE_UPDATE_MS then return false end
    state.last_phrase_update = now
    state.phrase = next_thinking_phrase(state.phrase)
    return true
end

---Starts a spinner timer and calls refresh after each frame advance.
---@param state Psst.progress.State
---@param opts { is_current: (fun(): boolean), refresh: (fun(): nil) }
---@return nil
function M.start(state, opts)
    M.stop(state)

    local timer = assert(vim.uv.new_timer(), "Failed to create agent progress timer")
    state.spinner_timer = timer
    timer:start(SPINNER_INTERVAL_MS, SPINNER_INTERVAL_MS, function()
        vim.schedule(function()
            if not opts.is_current() then return end
            state.spinner_frame = (state.spinner_frame % #SPINNER_FRAMES) + 1
            opts.refresh()
        end)
    end)
end

---Stops and closes an active spinner timer.
---@param state Psst.progress.State
---@return nil
function M.stop(state)
    local timer = state.spinner_timer
    if not timer then return end

    state.spinner_timer = nil
    if timer:is_closing() then error("Agent progress timer was closed outside its owner") end

    timer:stop()
    timer:close()
end

return M
