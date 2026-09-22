---@module "psst.process"
---Runs a configured harness in JSON mode and emits decoded stream events.

local M = {}

local log = require("psst.log")

---@class Psst.process.RunOpts
---@field executable string
---@field args string[]|nil
---@field stdin string
---@field cwd string|nil
---@field on_event fun(event: table): nil
---@field on_exit fun(result: vim.SystemCompleted): nil

---@param result vim.SystemCompleted
---@return string
function M.stderr_summary(result)
    local line = (result.stderr or ""):match("[^\n]*") or ""
    return line:gsub("^%s+", ""):gsub("%s+$", "")
end

---@param opts Psst.process.RunOpts
---@return vim.SystemObj
function M.json(opts)
    local protocol_error

    local function handle_line(line)
        if line == "" then return end
        local ok, event = pcall(vim.json.decode, line)
        if ok and type(event) == "table" then
            vim.schedule(function() opts.on_event(event) end)
            return
        end

        protocol_error = protocol_error or "Harness emitted malformed JSON"
        log.error(protocol_error, line)
    end

    local leftover = ""
    local cmd = { opts.executable }
    vim.list_extend(cmd, opts.args or {})

    return vim.system(cmd, {
        text = true,
        stdin = opts.stdin,
        cwd = opts.cwd,
        stdout = function(err, data)
            if err then
                log.error("JSON stream stdout error", err)
                return
            end
            if not data then return end
            local chunk = leftover .. data
            local parts = vim.split(chunk, "\n", { plain = true })
            leftover = parts[#parts]
            for i = 1, #parts - 1 do
                handle_line(parts[i])
            end
        end,
    }, function(result)
        if leftover ~= "" then
            handle_line(leftover)
            leftover = ""
        end
        if protocol_error and result.code == 0 then
            result = vim.tbl_extend("force", result, {
                code = 1,
                stderr = protocol_error,
            })
        end
        vim.schedule(function() opts.on_exit(result) end)
    end)
end

return M
