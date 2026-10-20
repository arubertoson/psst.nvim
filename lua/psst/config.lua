---@module "psst.config"
local M = {}

---@alias Psst.config.FloatSide "left"|"right"

---@class Psst.config.FloatOpts
---@field side Psst.config.FloatSide|nil
---@field width integer|nil
---@field before_open fun(layout: Psst.config.FloatLayout)|nil
---@field after_close fun(layout: Psst.config.FloatLayout)|nil

---@class Psst.config.FloatConfig
---@field side Psst.config.FloatSide
---@field width integer
---@field before_open fun(layout: Psst.config.FloatLayout)|nil
---@field after_close fun(layout: Psst.config.FloatLayout)|nil

---@class Psst.config.FloatLayout
---@field side Psst.config.FloatSide
---@field width integer

---@class Psst.config.KeymapOpts
---@field global boolean|nil
---@field float boolean|nil

---@class Psst.config.KeymapConfig
---@field global boolean
---@field float boolean

---@class Psst.config.ToolOpts
---@field inquire string[]|nil Inquiry allowlist; defaults to read, grep, find, ls. Empty disables tools.
---@field generate string[]|nil Generation allowlist; defaults to read, grep, find, ls. Empty disables tools.

---@class Psst.config.InstructionOpts
---@field inquire string|nil Additional literal instructions, appended to Psst's inquiry defaults.
---@field generate string|nil Additional literal instructions; generation output requirements remain in effect.

---@class Psst.config.Opts
---@field executable string|nil
---@field adapter string|nil
---@field session_dir string|nil
---@field model string|nil
---@field float Psst.config.FloatOpts|nil
---@field keymaps Psst.config.KeymapOpts|nil
---@field tools Psst.config.ToolOpts|nil
---@field instructions Psst.config.InstructionOpts|nil

---@class Psst.config.Config
---@field executable string
---@field adapter string
---@field session_dir string
---@field model string|nil
---@field float Psst.config.FloatConfig
---@field keymaps Psst.config.KeymapConfig
---@field tools Psst.config.ToolOpts
---@field instructions Psst.config.InstructionOpts

local defaults = {
    executable = "pi",
    adapter = "pi",
    session_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "psst", "sessions"),
    model = nil,
    float = {
        side = "right",
        width = 60,
    },
    keymaps = { global = true, float = true },
    tools = {
        inquire = { "read", "grep", "find", "ls" },
        generate = { "read", "grep", "find", "ls" },
    },
    instructions = {},
}

---@type Psst.config.Config
local config = vim.deepcopy(defaults)

local CONFIG_KEYS = {
    executable = true,
    adapter = true,
    session_dir = true,
    float = true,
    keymaps = true,
    model = true,
    tools = true,
    instructions = true,
}

local KEYMAP_KEYS = { global = true, float = true }
local TOOL_KEYS = { inquire = true, generate = true }
local INSTRUCTION_KEYS = { inquire = true, generate = true }

local FLOAT_KEYS = {
    side = true,
    width = true,
    before_open = true,
    after_close = true,
}

---@param value table
---@param allowed table<string, boolean>
---@param name string
local function validate_keys(value, allowed, name)
    for key in pairs(value) do
        if not allowed[key] then error(("unknown %s option: %s"):format(name, tostring(key))) end
    end
end

---@param value any
---@param name string
local function validate_nonempty_string(value, name)
    if type(value) ~= "string" or value == "" then error(name .. " must be a non-empty string") end
end

---@param opts Psst.config.Opts|nil
function M.setup(opts)
    if opts == nil then return end
    if type(opts) ~= "table" then error("psst config must be a table") end
    validate_keys(opts, CONFIG_KEYS, "psst config")

    for _, name in ipairs({ "executable", "adapter", "session_dir" }) do
        if opts[name] ~= nil then validate_nonempty_string(opts[name], "psst " .. name) end
    end
    if opts.model ~= nil then validate_nonempty_string(opts.model, "psst model") end

    if opts.tools ~= nil then
        if type(opts.tools) ~= "table" then error("psst tools config must be a table") end
        validate_keys(opts.tools, TOOL_KEYS, "psst tools")
        for intent, tools in pairs(opts.tools) do
            local name = "psst tools " .. intent
            if type(tools) ~= "table" or not vim.islist(tools) then
                error(name .. " must be a list")
            end
            for index, tool in ipairs(tools) do
                validate_nonempty_string(tool, ("%s[%d]"):format(name, index))
                if tool:find("[,%s]") or tool:find("^[+-]") then
                    error(name .. " entries must be individual tool names or patterns")
                end
            end
        end
    end

    if opts.instructions ~= nil then
        if type(opts.instructions) ~= "table" then
            error("psst instructions config must be a table")
        end
        validate_keys(opts.instructions, INSTRUCTION_KEYS, "psst instructions")
        for intent, text in pairs(opts.instructions) do
            if type(text) ~= "string" then
                error("psst instructions " .. intent .. " must be a string")
            end
        end
    end

    if opts.float ~= nil then
        if type(opts.float) ~= "table" then error("psst float config must be a table") end
        validate_keys(opts.float, FLOAT_KEYS, "psst float")

        if opts.float.side ~= nil and opts.float.side ~= "left" and opts.float.side ~= "right" then
            error("psst float side must be 'left' or 'right'")
        end
        if
            opts.float.width ~= nil
            and (
                type(opts.float.width) ~= "number"
                or opts.float.width < 1
                or opts.float.width % 1 ~= 0
            )
        then
            error("psst float width must be a positive integer")
        end
        for _, name in ipairs({ "before_open", "after_close" }) do
            if opts.float[name] ~= nil and type(opts.float[name]) ~= "function" then
                error("psst float " .. name .. " must be a function")
            end
        end
    end

    if opts.keymaps ~= nil then
        if type(opts.keymaps) ~= "table" then error("psst keymaps config must be a table") end
        validate_keys(opts.keymaps, KEYMAP_KEYS, "psst keymaps")
        for name, value in pairs(opts.keymaps) do
            if type(value) ~= "boolean" then
                error("psst keymaps " .. name .. " must be a boolean")
            end
        end
    end

    config = vim.tbl_deep_extend("force", config, opts)
    -- Allowlists replace rather than merge, including an explicitly empty list.
    for intent, tools in pairs(opts.tools or {}) do
        config.tools[intent] = vim.deepcopy(tools)
    end
end

---@return Psst.config.Config
function M.get() return config end

return M
