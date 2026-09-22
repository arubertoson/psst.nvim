---@module "psst.payload"
local M = {}

---@class Psst.payload.ContextItem
---@field kind string
---@field source boolean|nil
---@field path string|nil
---@field filetype string|nil
---@field start_line integer|nil
---@field end_line integer|nil
---@field symbol string|nil
---@field whole_file boolean|nil
---@field text string

---@class Psst.payload.Payload
---@field prompt string|nil
---@field context Psst.payload.ContextItem[]

---@param value string
local function escape_attribute(value)
    return value
        :gsub("&", "&amp;")
        :gsub('"', "&quot;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub("'", "&apos;")
end

---@param item Psst.payload.ContextItem
local function render_item(item)
    local tag = item.source and "file" or item.kind
    local attributes = {}
    if item.path and item.path ~= "" then
        local name = item.source and "name" or "file"
        attributes[#attributes + 1] = (' %s="%s"'):format(name, escape_attribute(item.path))
    end
    if item.symbol then
        attributes[#attributes + 1] = (' symbol="%s"'):format(escape_attribute(item.symbol))
    end
    if not item.whole_file and item.start_line and item.end_line then
        attributes[#attributes + 1] = (' lines="%d-%d"'):format(item.start_line, item.end_line)
    end
    return ("<%s%s>\n%s\n</%s>"):format(tag, table.concat(attributes), item.text, tag)
end

---@param payload Psst.payload.Payload
---@return string
function M.render(payload)
    local sections = {}
    for _, item in ipairs(payload.context) do
        sections[#sections + 1] = render_item(item)
    end
    if payload.prompt and payload.prompt ~= "" then sections[#sections + 1] = payload.prompt end
    return table.concat(sections, "\n\n")
end

return M
