---@module "psst.adapters.pi"
---Pi CLI command construction and streamed event interpretation.

local M = {}

local process = require("psst.process")

local INQUIRY_TOOLS = { "read", "ffgrep", "fffind" }

---@param args string[]
---@param target Psst.adapters.SessionTarget
---@param session_dir string
local function extend_with_session(args, target, session_dir)
    if target.kind == "none" then
        table.insert(args, "--no-session")
        return
    end

    vim.list_extend(args, { "--session-dir", session_dir, "--session-id", target.id })
end

---@param config Psst.config.Config
---@param request Psst.Request
---@param target Psst.adapters.SessionTarget
---@param intent Psst.adapters.Intent
---@return string[]
function M._command(config, request, target, intent)
    local args = { config.executable }

    if request.preset and request.preset ~= "" then
        vim.list_extend(args, { "--preset", request.preset })
    end

    if intent == "inquire" then
        vim.list_extend(args, { "--tools", table.concat(INQUIRY_TOOLS, ",") })
    end

    vim.list_extend(args, { "--mode", "json" })
    extend_with_session(args, target, config.session_dir)
    return args
end

---@param opts Psst.adapters.RunOpts
---@return vim.SystemObj
function M.run(opts)
    local command = M._command(opts.config, opts.request, opts.target, opts.intent)
    return process.json({
        executable = command[1],
        args = vim.list_slice(command, 2),
        stdin = opts.stdin,
        cwd = opts.cwd,
        on_event = opts.on_event,
        on_exit = opts.on_exit,
    })
end

---@param event table
---@param handlers Psst.adapters.Handlers
function M.dispatch(event, handlers)
    if event.type ~= "message_update" then return end
    local update = event.assistantMessageEvent
    if not update or type(update.delta) ~= "string" then return end

    if update.type == "thinking_delta" then
        if handlers.on_thinking then handlers.on_thinking(update.delta) end
    elseif update.type == "text_delta" and handlers.on_text then
        handlers.on_text(update.delta)
    end
end

return M
