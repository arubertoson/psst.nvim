---@module "psst"
---Opens a low-friction inquiry beside the current work, carrying editor context
---to a configured coding-agent harness. This module is the public facade;
---destination-specific UI state lives under `psst.*`.
---
---Example:
---```lua
---local psst = require("psst")
---local channels = require("psst.channels")
---local collect = require("psst.collect")
---psst.setup({ executable = "pi-dev", adapter = "pi" })
---psst.send({
---  destination = channels.DESTINATION.FLOAT,
---  collect = { collect.COLLECT.BLOCK },
---  prompt = "Explain this code",
---})
---```

---@class Psst.Request
---@field destination Psst.channels.Destination
---@field force_new_session boolean|nil
---@field collect Psst.collect.Type[]|nil
---@field prompt string|nil
---@field preset string|nil
---@field context Psst.payload.ContextItem[]|nil

---@class Psst.ConfigState
---@field config Psst.config.Config
---@field state Psst.InvocationState

---@class Psst.Selection
---@field start_row integer 0-based
---@field start_col integer 0-based, inclusive
---@field end_row integer 0-based
---@field end_col integer 0-based, exclusive

---@class Psst.InvocationState
---@field cwd string
---@field bufnr integer
---@field path string
---@field filetype string
---@field winid integer
---@field cursor [integer, integer]
---@field selection Psst.Selection|nil

---@class Psst.PromptOpts
---@field visual_mode string|nil
---@field collect Psst.collect.Type[]|nil

local M = {}

local config = require("psst.config")
local adapters = require("psst.adapters")
local payload = require("psst.payload")
local collect = require("psst.collect")
local channels = require("psst.channels")
local prompt_ui = require("psst.prompt")
local request_validation = require("psst.request")
local session = require("psst.session")

---@param bufnr integer
---@param visual_mode string|nil
---@return Psst.Selection|nil
local function capture_selection(bufnr, visual_mode)
    if not visual_mode then return nil end

    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    if start_pos[2] == 0 or end_pos[2] == 0 then return nil end
    if start_pos[1] ~= 0 and start_pos[1] ~= bufnr then return nil end
    if end_pos[1] ~= 0 and end_pos[1] ~= bufnr then return nil end

    local segments = vim.fn.getregionpos(start_pos, end_pos, {
        type = visual_mode,
        eol = true,
    })
    if #segments == 0 then return nil end

    local first = segments[1][1]
    local last = segments[#segments][2]
    local end_row = last[2] - 1
    local end_line = vim.api.nvim_buf_get_lines(bufnr, end_row, end_row + 1, false)[1] or ""

    return {
        start_row = first[2] - 1,
        start_col = math.max(0, first[3] - 1),
        end_row = end_row,
        end_col = math.min(#end_line, math.max(0, last[3])),
    }
end

---@param visual_mode string|nil
---@return Psst.InvocationState
local function capture_invocation_state(visual_mode)
    local bufnr = vim.api.nvim_get_current_buf()
    local winid = vim.api.nvim_get_current_win()

    return {
        cwd = vim.fn.getcwd(),
        bufnr = bufnr,
        path = vim.api.nvim_buf_get_name(bufnr),
        filetype = vim.api.nvim_get_option_value("filetype", { buf = bufnr }),
        winid = winid,
        cursor = vim.api.nvim_win_get_cursor(winid),
        selection = capture_selection(bufnr, visual_mode),
    }
end

---@param request Psst.Request
---@param state Psst.InvocationState
---@return boolean
local function send(request, state)
    request_validation.validate(request)
    if request.destination == channels.DESTINATION.FLOAT and session.is_streaming() then
        vim.notify("An agent response is already streaming", vim.log.levels.WARN)
        return false
    end

    local cfg = config.get()
    local adapter = adapters.get(cfg.adapter)
    ---@type Psst.ConfigState
    local ctx = { config = cfg, state = state }

    local channel = channels.get(request.destination)

    local items = request.context or {}
    if not request.context and request.collect and #request.collect > 0 then
        items = collect.resolve(state, request.collect)
    end

    local message = payload.render({
        prompt = request.prompt,
        context = items,
    })
    local label = vim.fn.fnamemodify(cfg.executable, ":t")
    local response
    ---@type Psst.adapters.SessionTarget
    local target = { kind = "none" }
    ---@type Psst.adapters.Intent
    local intent = "generate"

    if request.destination == channels.DESTINATION.FLOAT then
        local inquiry_session
        inquiry_session, response =
            session.begin_read(state.cwd, label, request.force_new_session == true)
        target = { kind = "explicit", id = inquiry_session.id }
        intent = "inquire"
        vim.fs.mkdir(cfg.session_dir, { parents = true })
    end

    local function run(stdin, on_event, on_exit)
        return adapter.run({
            config = cfg,
            request = request,
            target = target,
            intent = intent,
            stdin = stdin,
            cwd = state.cwd,
            on_event = on_event,
            on_exit = on_exit,
        })
    end

    ---@type Psst.channels.Transport
    local transport = {
        message = message,
        response = response,
        run = run,
        dispatch = adapter.dispatch,
    }

    return channel.send(transport, ctx)
end

---@param request Psst.Request
---@return boolean
function M.send(request) return send(request, capture_invocation_state()) end

---@param opts Psst.PromptOpts|nil
function M.prompt(opts)
    local visual_mode = opts and opts.visual_mode
    if visual_mode == "\22" then
        vim.notify("Agent prompts do not support blockwise selections", vim.log.levels.ERROR)
        return false
    end

    local state = capture_invocation_state(visual_mode)
    return prompt_ui.open({
        send = function(request) return send(request, state) end,
        collect = opts and opts.collect,
        cwd = state.cwd,
        invocation = state,
    })
end

M.float = {}

---@param direction "down"|"up"
function M.float.scroll(direction) return require("psst.channels.float").scroll(direction) end

local function navigate_response(delta)
    if session.navigate_response(delta) then require("psst.channels.float").show_selected() end
end

local function navigate_session(delta)
    if session.navigate_session(delta) then require("psst.channels.float").show_selected() end
end

function M.float.response_prev() navigate_response(-1) end

function M.float.response_next() navigate_response(1) end

function M.float.session_prev() navigate_session(-1) end

function M.float.session_next() navigate_session(1) end

function M.float.focus() return require("psst.channels.float").focus() end

function M.float.close() return require("psst.channels.float").close() end

---@return boolean
function M.sessions_clear()
    if session.is_streaming() then
        vim.notify(
            "Cannot clear agent sessions while a response is streaming",
            vim.log.levels.ERROR
        )
        return false
    end

    local session_count, response_count = session.counts()
    local session_dir = config.get().session_dir
    local store_exists = vim.uv.fs_stat(session_dir) ~= nil
    local ok, err = pcall(vim.fs.rm, session_dir, { recursive = true })
    if not ok and not tostring(err):find("ENOENT", 1, true) then
        vim.notify("Failed to clear agent sessions: " .. tostring(err), vim.log.levels.ERROR)
        return false
    end

    require("psst.channels.float").close()
    session.clear()

    if session_count == 0 and response_count == 0 and not store_exists then
        vim.notify("Agent sessions already empty", vim.log.levels.INFO)
    else
        vim.notify(
            ("Cleared %d agent sessions and %d responses"):format(session_count, response_count),
            vim.log.levels.INFO
        )
    end
    return true
end

---@param opts Psst.config.Opts|nil
function M.setup(opts)
    config.setup(opts)
    vim.api.nvim_create_user_command("PsstSessionsClear", M.sessions_clear, {
        desc = "Clear psst sessions and responses",
        force = true,
    })
end

return M
