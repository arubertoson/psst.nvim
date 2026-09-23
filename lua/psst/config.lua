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

---@class Psst.config.KeymapConfig
---@field global boolean

---@class Psst.config.Opts
---@field executable string|nil
---@field adapter string|nil
---@field session_dir string|nil
---@field float Psst.config.FloatOpts|nil
---@field keymaps Psst.config.KeymapOpts|nil

---@class Psst.config.Config
---@field executable string
---@field adapter string
---@field session_dir string
---@field float Psst.config.FloatConfig
---@field keymaps Psst.config.KeymapConfig

local defaults = {
    executable = "pi",
    adapter = "pi",
    session_dir = vim.fs.joinpath(vim.fn.stdpath("cache"), "psst", "sessions"),
    float = {
        side = "right",
        width = 60,
    },
    keymaps = { global = false },
}

---@type Psst.config.Config
local config = vim.deepcopy(defaults)

local CONFIG_KEYS = {
    executable = true,
    adapter = true,
    session_dir = true,
    float = true,
    keymaps = true,
}

local KEYMAP_KEYS = { global = true }

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
        if opts.keymaps.global ~= nil and type(opts.keymaps.global) ~= "boolean" then
            error("psst keymaps global must be a boolean")
        end
    end

    config = vim.tbl_deep_extend("force", config, opts)
end

---@return Psst.config.Config
function M.get() return config end

return M
