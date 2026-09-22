---@module "psst.reference"
---Recognizes inline context syntax in prompt text. References are derived from
---the current text on every parse and never own persistent state.

local M = {}

---@alias Psst.reference.State "editing"|"pending"|"resolved"|"unresolved"

---@class Psst.reference.Span
---@field start_row integer
---@field start_col integer
---@field end_row integer
---@field end_col integer

---@class Psst.reference.LineSelector
---@field kind "lines"
---@field start_line integer|nil
---@field end_line integer|nil

---@class Psst.reference.SymbolSelector
---@field kind "symbol"
---@field name string

---@alias Psst.reference.Selector Psst.reference.LineSelector|Psst.reference.SymbolSelector

---@class Psst.reference.Reference
---@field raw string
---@field path string|nil
---@field selector Psst.reference.Selector|nil
---@field span Psst.reference.Span
---@field state Psst.reference.State
---@field error string|nil
---@field incomplete boolean
---@field invalid boolean

local OPENING_BOUNDARY = {
    ["("] = true,
    ["["] = true,
    ["{"] = true,
    ["<"] = true,
    ['"'] = true,
    ["'"] = true,
}

local CLOSING_PUNCTUATION = {
    [","] = true,
    [";"] = true,
    ["!"] = true,
    ["?"] = true,
    [")"] = true,
    ["]"] = true,
    ["}"] = true,
    [">"] = true,
    ['"'] = true,
    ["'"] = true,
}

---@param char string
local function is_start_boundary(char)
    return char == "" or char:match("%s") ~= nil or char == "`" or OPENING_BOUNDARY[char] == true
end

---@param char string
local function is_end_boundary(char)
    return char:match("%s") ~= nil or char == "`" or CLOSING_PUNCTUATION[char] == true
end

---@param body string
---@return string|nil, Psst.reference.Selector|nil, boolean, boolean, string|nil
local function parse_body(body)
    if body == "" then return "", nil, true, false, nil end

    local hash = body:find("#", 1, true)
    local colon = body:find(":", 1, true)
    if hash and colon and colon < hash then
        return nil, nil, false, true, "cannot combine symbol and line selectors"
    end

    if hash then
        local path = body:sub(1, hash - 1)
        local name = body:sub(hash + 1)
        if name:find("#", 1, true) then
            return path ~= "" and path or nil, nil, false, true, "invalid symbol selector"
        end
        return path ~= "" and path or nil, { kind = "symbol", name = name }, name == "", false, nil
    end

    if colon then
        local path = body:sub(1, colon - 1)
        local range = body:sub(colon + 1)
        local start_text, end_text = range:match("^(%d*)%-(%d*)$")
        if not start_text then
            return path ~= "" and path or nil, nil, false, true, "invalid line selector"
        end

        local incomplete = start_text == "" or end_text == ""
        return path ~= "" and path or nil,
            {
                kind = "lines",
                start_line = start_text ~= "" and tonumber(start_text) or nil,
                end_line = end_text ~= "" and tonumber(end_text) or nil,
            },
            incomplete,
            false,
            nil
    end

    return body, nil, false, false, nil
end

---@param cursor [integer, integer]|nil 0-based row and byte column
---@param span Psst.reference.Span
function M.cursor_in_span(cursor, span)
    if not cursor then return false end
    local row, col = cursor[1], cursor[2]
    if row < span.start_row or row > span.end_row then return false end
    if row == span.start_row and col < span.start_col then return false end
    -- A cursor immediately after the final byte is still editing the token.
    if row == span.end_row and col > span.end_col then return false end
    return true
end

---@param line string
---@param row integer
---@param cursor [integer, integer]|nil
---@param out Psst.reference.Reference[]
local function parse_line(line, row, cursor, out)
    local index = 1
    while index <= #line do
        local at = line:find("@", index, true)
        if not at then return end

        local previous = at == 1 and "" or line:sub(at - 1, at - 1)
        if not is_start_boundary(previous) then
            index = at + 1
        else
            local finish = at
            while finish < #line do
                local char = line:sub(finish + 1, finish + 1)
                if is_end_boundary(char) then break end
                finish = finish + 1
            end

            -- Keep a final period while the cursor is still editing it so path
            -- completion can continue through extensions. Once the cursor
            -- leaves, final periods are prose punctuation.
            local cursor_on_token = cursor
                and cursor[1] == row
                and cursor[2] >= at - 1
                and cursor[2] <= finish
            if not cursor_on_token then
                while finish > at and line:sub(finish, finish) == "." do
                    finish = finish - 1
                end
            end

            local raw = line:sub(at, finish)
            local path, selector, incomplete, invalid, syntax_error = parse_body(raw:sub(2))
            local span = {
                start_row = row,
                start_col = at - 1,
                end_row = row,
                end_col = finish,
            }
            local editing = incomplete and M.cursor_in_span(cursor, span)
            local state
            local ref_error
            if invalid then
                state = "unresolved"
                ref_error = syntax_error
            elseif incomplete then
                state = editing and "editing" or "unresolved"
                ref_error = editing and nil or "incomplete reference"
            else
                state = "pending"
            end
            out[#out + 1] = {
                raw = raw,
                path = path,
                selector = selector,
                span = span,
                state = state,
                error = ref_error,
                incomplete = incomplete,
                invalid = invalid,
            }
            index = math.max(at + 1, finish + 1)
        end
    end
end

---@param text string
---@param cursor [integer, integer]|nil 0-based row and byte column
---@return Psst.reference.Reference[]
function M.parse(text, cursor)
    local references = {}
    local row = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        parse_line(line, row, cursor, references)
        row = row + 1
    end
    return references
end

---@param ref Psst.reference.Reference
---@return string
local function identity(ref)
    return table.concat({
        ref.raw,
        ref.span.start_row,
        ref.span.start_col,
        ref.span.end_row,
        ref.span.end_col,
    }, "\0")
end

---@param references Psst.reference.Reference[]
---@param cursor [integer, integer]|nil
---@param text string
---@return boolean changed
function M.update_cursor(references, cursor, text)
    local previous = {}
    for _, ref in ipairs(references) do
        previous[identity(ref)] = ref
    end

    local changed = false
    local reparsed = M.parse(text, cursor)
    for _, ref in ipairs(reparsed) do
        local old = previous[identity(ref)]
        if old and not ref.incomplete and not ref.invalid then
            ref.state = old.state
            ref.error = old.error
        elseif not old then
            changed = true
        end
    end
    if #references ~= #reparsed then changed = true end

    for index = #references, 1, -1 do
        references[index] = nil
    end
    vim.list_extend(references, reparsed)
    return changed
end

---@param ref Psst.reference.Reference
---@param resolution_error string|nil
function M.classify(ref, resolution_error)
    if not resolution_error then
        ref.state = "resolved"
        ref.error = nil
    else
        ref.state = "unresolved"
        ref.error = resolution_error
    end
end

---@param line string
---@param cursor_col integer 0-based byte column
---@return Psst.reference.Reference|nil
function M.at_cursor(line, cursor_col)
    local references = M.parse(line, { 0, cursor_col })
    for _, reference in ipairs(references) do
        if M.cursor_in_span({ 0, cursor_col }, reference.span) then return reference end
    end
    return nil
end

return M
