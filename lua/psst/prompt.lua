---@module "psst.prompt"
---Owns the floating agent prompt and its derived Inline Reference preview.

local M = {}

local constants = require("psst.constants")
local channels = require("psst.channels")
local collect = require("psst.collect")
local context = require("psst.context")
local session = require("psst.session")
local ui = require("psst.ui")

---@class Psst.prompt.Deps
---@field send fun(request: Psst.Request): boolean
---@field collect Psst.collect.Type[]|nil
---@field cwd string
---@field invocation Psst.InvocationState

local PROMPT_LAYOUT = constants.UI.PROMPT
local OVERVIEW_LAYOUT = constants.UI.CONTEXT_OVERVIEW
local PROMPT_MIN_ROWS = PROMPT_LAYOUT.MIN_ROWS
local PROMPT_MAX_ROWS = PROMPT_LAYOUT.MAX_ROWS
local PROMPT_LEFT_PADDING = PROMPT_LAYOUT.LEFT_PADDING
local PROMPT_BORDER_INSET = 3
local PLACEHOLDER_TEXT = "<user types here>"
local PROMPT_CLOSE_KEY = "q"
local PREVIEW_DELAY_MS = 90

local BLOCK_COLLECT = { collect.COLLECT.BLOCK }

---@class Psst.prompt.State
---@field buf integer
---@field win integer
---@field footer_ns integer
---@field reference_ns integer
---@field augroup integer
---@field timer uv.uv_timer_t
---@field refresh_id integer
---@field send fun(request: Psst.Request): boolean
---@field collect Psst.collect.Type[]
---@field cwd string
---@field invocation Psst.InvocationState
---@field references Psst.reference.Reference[]
---@field preview_win integer|nil
---@field preview_buf integer|nil

---@type Psst.prompt.State|nil
local _prompt_state = nil

---@class Psst.prompt.Draft
---@field lines string[]
---@field cursor integer[]

---@type Psst.prompt.Draft
local _draft = { lines = { "" }, cursor = { 1, 0 } }

---@class Psst.prompt.Action
---@field key string
---@field label string

---@param state Psst.prompt.State
---@return Psst.prompt.Action[]
local function footer_actions(state)
    local continuable, session_index = session.can_continue(state.cwd)
    return {
        {
            key = "CR",
            label = continuable and ("continue S%d"):format(session_index) or "read",
        },
        { key = "^CR", label = "new session" },
        { key = "^G", label = "generate" },
        { key = "^X", label = "overview" },
    }
end

local function prompt_space()
    return ui.editor_space({
        horizontal_margin = PROMPT_LAYOUT.HORIZONTAL_MARGIN,
        vertical_margin = PROMPT_LAYOUT.VERTICAL_MARGIN,
        border_columns = PROMPT_LAYOUT.BORDER_COLUMNS,
        border_rows = PROMPT_LAYOUT.BORDER_ROWS,
    })
end

local function prompt_width()
    local space = prompt_space()
    return ui.responsive_size(
        space.width,
        PROMPT_LAYOUT.MIN_WIDTH,
        PROMPT_LAYOUT.MAX_WIDTH,
        PROMPT_LAYOUT.WIDTH_RATIO
    )
end

---@param border string|table
---@param index integer
---@return string
local function horizontal_border_char(border, index)
    if type(border) == "table" then
        local segment = border[index]
        return type(segment) == "table" and segment[1] or segment
    end
    return ({
        single = "─",
        rounded = "─",
        double = "═",
        bold = "━",
        solid = " ",
        shadow = " ",
        none = "",
    })[border] or "─"
end

---@param buf integer
---@param width integer
local function prompt_content_rows(buf, width)
    local text_width = math.max(1, width - PROMPT_LEFT_PADDING)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local rows = 0
    for _, line in ipairs(lines) do
        local line_width = vim.fn.strdisplaywidth(line)
        rows = rows + math.max(1, math.ceil((line_width + 1) / text_width))
    end
    return math.max(1, math.min(rows, PROMPT_MAX_ROWS))
end

---@param buf integer
local function prompt_win_config(buf)
    local border = constants.UI.BORDER_ROUNDED
    local title_inset = string.rep(horizontal_border_char(border, 2), PROMPT_BORDER_INSET)
    local width = prompt_width()
    local content_rows = prompt_content_rows(buf, width)
    local desired_height = math.max(PROMPT_MIN_ROWS, content_rows) + 2
    local space = prompt_space()
    local max_height = ui.responsive_size(
        space.height,
        PROMPT_MIN_ROWS + 2,
        PROMPT_MAX_ROWS + 2,
        PROMPT_LAYOUT.HEIGHT_RATIO
    )
    local height = math.min(desired_height, max_height)
    local editor_rows = vim.o.lines - vim.o.cmdheight
    return {
        relative = "editor",
        row = ui.centered_offset(editor_rows, height, PROMPT_LAYOUT.BORDER_ROWS),
        col = ui.centered_offset(vim.o.columns, width, PROMPT_LAYOUT.BORDER_COLUMNS),
        width = width,
        height = height,
        style = constants.UI.STYLE_MINIMAL,
        border = border,
        title = {
            { title_inset, "FloatBorder" },
            { " prompt ", "FloatTitle" },
        },
        title_pos = constants.UI.TITLE_POS_LEFT,
        zindex = PROMPT_LAYOUT.ZINDEX,
    }
end

---@param item Psst.payload.ContextItem
local function context_label(item)
    if item.kind == "diagnostic" then return "diagnostic" end
    local name = item.path and vim.fs.basename(item.path) or item.kind
    if item.symbol then
        return ("%s#%s:%d-%d"):format(name, item.symbol, item.start_line, item.end_line)
    end
    if item.whole_file then return name end
    if item.start_line and item.end_line then
        return ("%s %s:%d-%d"):format(item.kind, name, item.start_line, item.end_line)
    end
    return name
end

---@param state Psst.prompt.State
local function render_footer(state)
    local buf = state.buf
    local total = vim.api.nvim_buf_line_count(buf)
    local footer_idx = total - 1
    local first_line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    local show_placeholder = total == 1 and first_line == ""

    local action_chunks = {}
    for index, action in ipairs(footer_actions(state)) do
        if index > 1 then action_chunks[#action_chunks + 1] = { "   ", "Normal" } end
        action_chunks[#action_chunks + 1] = { "[" .. action.key .. "]", "Special" }
        action_chunks[#action_chunks + 1] = {
            " " .. action.label,
            constants.UI.HIGHLIGHT_COMMENT,
        }
    end
    local border = constants.UI.BORDER_ROUNDED
    action_chunks[#action_chunks + 1] = {
        string.rep(horizontal_border_char(border, 6), PROMPT_BORDER_INSET),
        "FloatBorder",
    }
    vim.api.nvim_win_set_config(state.win, {
        footer = action_chunks,
        footer_pos = "right",
    })

    vim.api.nvim_buf_clear_namespace(buf, state.footer_ns, 0, -1)
    if show_placeholder then
        vim.api.nvim_buf_set_extmark(buf, state.footer_ns, footer_idx, 0, {
            virt_text = { { PLACEHOLDER_TEXT, constants.UI.HIGHLIGHT_COMMENT } },
            virt_text_pos = "overlay",
        })
    end
end

---@param state Psst.prompt.State
local function render_references(state)
    vim.api.nvim_buf_clear_namespace(state.buf, state.reference_ns, 0, -1)
    local highlights = {
        resolved = "Special",
        pending = constants.UI.HIGHLIGHT_COMMENT,
        editing = constants.UI.HIGHLIGHT_COMMENT,
        unresolved = "DiagnosticError",
    }
    for _, ref in ipairs(state.references) do
        vim.api.nvim_buf_set_extmark(
            state.buf,
            state.reference_ns,
            ref.span.start_row,
            ref.span.start_col,
            {
                end_row = ref.span.end_row,
                end_col = ref.span.end_col,
                hl_group = highlights[ref.state],
            }
        )
    end
end

---@param state Psst.prompt.State
local function resize_prompt(state)
    if not vim.api.nvim_win_is_valid(state.win) then return end
    vim.api.nvim_win_set_config(state.win, prompt_win_config(state.buf))
    render_footer(state)
end

---@param buf integer
local function read_prompt_text(buf)
    return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

---@param state Psst.prompt.State
local function prompt_cursor(state)
    local cursor = vim.api.nvim_win_get_cursor(state.win)
    return { cursor[1] - 1, cursor[2] }
end

---@param state Psst.prompt.State
local function build_context(state)
    return context.build({
        prompt = read_prompt_text(state.buf),
        cwd = state.cwd,
        invocation = state.invocation,
        collect = state.collect,
    })
end

---@param state Psst.prompt.State
---@param references Psst.reference.Reference[]
local function set_references(state, references) state.references = references end

---@param state Psst.prompt.State
local function parse_prompt(state)
    set_references(state, context.parse(read_prompt_text(state.buf), prompt_cursor(state)))
    render_references(state)
end

---@type fun(state: Psst.prompt.State)
local request_validation

---@param state Psst.prompt.State
local function update_cursor_state(state)
    local changed =
        context.update_cursor(state.references, prompt_cursor(state), read_prompt_text(state.buf))
    render_references(state)
    if changed then request_validation(state) end
end

---@param state Psst.prompt.State
local function validate_prompt(state)
    context.validate(state.references, state.cwd, state.invocation.bufnr)
    render_references(state)
end

---@param state Psst.prompt.State
request_validation = function(state)
    state.refresh_id = state.refresh_id + 1
    local refresh_id = state.refresh_id
    state.timer:stop()
    state.timer:start(
        PREVIEW_DELAY_MS,
        0,
        vim.schedule_wrap(function()
            if _prompt_state == state and state.refresh_id == refresh_id then
                validate_prompt(state)
            end
        end)
    )
end

---@param state Psst.prompt.State
local function prompt_changed(state)
    parse_prompt(state)
    resize_prompt(state)
    request_validation(state)
end

---@param discard_draft boolean|nil
local function close_prompt(discard_draft)
    if not _prompt_state then return end
    local state = _prompt_state
    _prompt_state = nil

    if discard_draft then
        _draft = { lines = { "" }, cursor = { 1, 0 } }
    elseif vim.api.nvim_buf_is_valid(state.buf) then
        _draft.lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
        if vim.api.nvim_win_is_valid(state.win) then
            _draft.cursor = vim.api.nvim_win_get_cursor(state.win)
            if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
                local line = _draft.lines[_draft.cursor[1]]
                _draft.cursor[2] = math.min(_draft.cursor[2] + 1, #line)
            end
        else
            local row = #_draft.lines
            _draft.cursor = { row, #_draft.lines[row] }
        end
    end

    state.timer:stop()
    if not state.timer:is_closing() then state.timer:close() end
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
        vim.api.nvim_win_close(state.preview_win, true)
    end
    ui.close_win_buf(state.win, state.buf)
    vim.cmd("stopinsert")
end

---@param destination Psst.channels.Destination
---@param force_new_session boolean|nil
local function submit_prompt(destination, force_new_session)
    if not _prompt_state then return end
    local state = _prompt_state
    local prompt_text = read_prompt_text(state.buf)
    if prompt_text:match("^%s*$") then return end

    local built = build_context(state)
    set_references(state, built.references)
    render_references(state)
    render_footer(state)
    if #built.blocking > 0 then
        local ref = built.blocking[1]
        vim.notify(("Cannot submit unresolved reference %s"):format(ref.raw), vim.log.levels.ERROR)
        return
    end

    local sent = state.send({
        destination = destination,
        force_new_session = force_new_session,
        collect = state.collect,
        context = built.context,
        prompt = prompt_text,
    })
    if sent then close_prompt(true) end
end

local function submit_float_read() submit_prompt(channels.DESTINATION.FLOAT, false) end
local function submit_float_new_session() submit_prompt(channels.DESTINATION.FLOAT, true) end

---@param buf integer
local function context_overview_win_config(buf)
    local space = ui.editor_space({
        horizontal_margin = OVERVIEW_LAYOUT.HORIZONTAL_MARGIN,
        vertical_margin = OVERVIEW_LAYOUT.VERTICAL_MARGIN,
        border_columns = OVERVIEW_LAYOUT.BORDER_COLUMNS,
        border_rows = OVERVIEW_LAYOUT.BORDER_ROWS,
    })
    local width = ui.responsive_size(
        space.width,
        OVERVIEW_LAYOUT.MIN_WIDTH,
        OVERVIEW_LAYOUT.MAX_WIDTH,
        OVERVIEW_LAYOUT.WIDTH_RATIO
    )
    local max_height = ui.responsive_size(
        space.height,
        OVERVIEW_LAYOUT.MIN_HEIGHT,
        OVERVIEW_LAYOUT.MAX_HEIGHT,
        OVERVIEW_LAYOUT.HEIGHT_RATIO
    )
    local desired_height =
        math.max(OVERVIEW_LAYOUT.MIN_HEIGHT, vim.api.nvim_buf_line_count(buf) + 2)
    local height = math.min(desired_height, max_height)
    local editor_rows = vim.o.lines - vim.o.cmdheight
    return {
        relative = "editor",
        row = ui.centered_offset(editor_rows, height, OVERVIEW_LAYOUT.BORDER_ROWS),
        col = ui.centered_offset(vim.o.columns, width, OVERVIEW_LAYOUT.BORDER_COLUMNS),
        width = width,
        height = height,
        style = constants.UI.STYLE_MINIMAL,
        border = constants.UI.BORDER_ROUNDED,
        title = " context overview ",
        title_pos = constants.UI.TITLE_POS_LEFT,
        zindex = PROMPT_LAYOUT.ZINDEX + 1,
    }
end

---@param state Psst.prompt.State
local function resize_context_overview(state)
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
        vim.api.nvim_win_set_config(
            state.preview_win,
            context_overview_win_config(assert(state.preview_buf))
        )
    end
end

---@param state Psst.prompt.State
local function close_context_overview(state)
    if state.preview_win and vim.api.nvim_win_is_valid(state.preview_win) then
        vim.api.nvim_win_close(state.preview_win, true)
    end
end

---@param built Psst.context.BuildResult
local function context_overview_lines(built)
    local lines = { "Context overview", "", ("Context Items (%d)"):format(#built.context) }
    if #built.context == 0 then
        lines[#lines + 1] = "None"
    else
        for index, item in ipairs(built.context) do
            lines[#lines + 1] = ("%d. %s"):format(index, context_label(item))
        end
    end

    if #built.blocking > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("Unresolved references (%d)"):format(#built.blocking)
        for _, ref in ipairs(built.blocking) do
            local marker = ref.state == "editing" and "…" or "?"
            local detail = ref.error and (" — " .. ref.error) or ""
            lines[#lines + 1] = ("%s %s%s"):format(marker, ref.raw, detail)
        end
    end
    return lines
end

---@param state Psst.prompt.State
local function show_context_overview(state)
    local built = build_context(state)
    set_references(state, built.references)
    render_references(state)
    render_footer(state)

    close_context_overview(state)
    local overview_lines = context_overview_lines(built)
    local preview_buf = ui.create_scratch_buf({
        filetype = constants.UI.FILETYPE_MARKDOWN,
        lines = overview_lines,
    })
    vim.bo[preview_buf].modifiable = false
    vim.bo[preview_buf].readonly = true
    local preview_win =
        vim.api.nvim_open_win(preview_buf, false, context_overview_win_config(preview_buf))
    state.preview_buf = preview_buf
    state.preview_win = preview_win

    local close = function()
        if _prompt_state == state then close_context_overview(state) end
    end
    vim.keymap.set("n", "q", close, { buffer = preview_buf, silent = true })
    vim.keymap.set("n", "<Esc>", close, { buffer = preview_buf, silent = true })
    vim.api.nvim_create_autocmd("WinClosed", {
        group = state.augroup,
        pattern = tostring(preview_win),
        once = true,
        callback = function()
            state.preview_win = nil
            state.preview_buf = nil
            vim.schedule(function()
                if _prompt_state == state and vim.api.nvim_win_is_valid(state.win) then
                    vim.api.nvim_set_current_win(state.win)
                    vim.cmd("startinsert")
                end
            end)
        end,
    })
    vim.api.nvim_set_current_win(preview_win)
    vim.cmd("stopinsert")
    vim.api.nvim_win_set_cursor(preview_win, { 1, 0 })
end

---@param deps Psst.prompt.Deps
function M.open(deps)
    if _prompt_state then
        local prompt_is_valid = vim.api.nvim_win_is_valid(_prompt_state.win)
            and vim.api.nvim_buf_is_valid(_prompt_state.buf)
            and vim.api.nvim_win_get_buf(_prompt_state.win) == _prompt_state.buf
        if prompt_is_valid then
            vim.api.nvim_set_current_win(_prompt_state.win)
            return
        end
        close_prompt()
    end

    local invocation_buf = deps.invocation.bufnr
    local buf = ui.create_scratch_buf({
        filetype = constants.UI.FILETYPE_PROMPT,
        lines = vim.deepcopy(_draft.lines),
    })
    vim.bo[buf].syntax = constants.UI.FILETYPE_MARKDOWN
    vim.b[buf].psst_prompt = true
    vim.b[buf].psst_completion_cwd = deps.cwd
    vim.b[buf].psst_completion_invocation_buf = invocation_buf

    local win = vim.api.nvim_open_win(buf, true, prompt_win_config(buf))
    ui.apply_win_options(win, {
        wrap = true,
        linebreak = true,
        cursorline = false,
        foldcolumn = tostring(PROMPT_LEFT_PADDING),
        foldenable = false,
    })
    local draft_line = _draft.lines[_draft.cursor[1]]
    vim.api.nvim_win_set_cursor(win, {
        _draft.cursor[1],
        math.min(_draft.cursor[2], math.max(0, #draft_line - 1)),
    })

    local footer_ns = vim.api.nvim_create_namespace(constants.NAMESPACE.PROMPT_FOOTER)
    local reference_ns = vim.api.nvim_create_namespace(constants.NAMESPACE.PROMPT_REFERENCE)
    local augroup = vim.api.nvim_create_augroup(constants.AUGROUP.PROMPT, { clear = true })
    local timer = assert(vim.uv.new_timer())

    ---@type Psst.prompt.State
    local state = {
        buf = buf,
        win = win,
        footer_ns = footer_ns,
        reference_ns = reference_ns,
        augroup = augroup,
        timer = timer,
        refresh_id = 0,
        send = deps.send,
        collect = deps.collect or BLOCK_COLLECT,
        cwd = deps.cwd,
        invocation = deps.invocation,
        references = {},
        preview_win = nil,
        preview_buf = nil,
    }
    _prompt_state = state
    parse_prompt(state)
    resize_prompt(state)

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "CompleteDone" }, {
        group = augroup,
        buffer = buf,
        callback = function() prompt_changed(state) end,
    })
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = augroup,
        buffer = buf,
        callback = function() update_cursor_state(state) end,
    })
    vim.api.nvim_create_autocmd("WinLeave", {
        group = augroup,
        buffer = buf,
        callback = function()
            vim.schedule(function()
                if _prompt_state ~= state then return end
                local current = vim.api.nvim_get_current_win()
                if current ~= state.win and current ~= state.preview_win then close_prompt() end
            end)
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
        group = augroup,
        callback = function()
            if _prompt_state ~= state then return end
            resize_prompt(state)
            resize_context_overview(state)
        end,
    })

    local map_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set({ "n", "i" }, "<CR>", submit_float_read, map_opts)
    vim.keymap.set({ "n", "i" }, "<C-CR>", submit_float_new_session, map_opts)
    vim.keymap.set(
        { "n", "i" },
        "<C-g>",
        function() submit_prompt(channels.DESTINATION.EDITOR, nil) end,
        map_opts
    )
    vim.keymap.set({ "n", "i" }, "<C-x>", function()
        if _prompt_state then show_context_overview(_prompt_state) end
    end, map_opts)
    vim.keymap.set("n", PROMPT_CLOSE_KEY, close_prompt, map_opts)

    vim.cmd("startinsert")
    vim.api.nvim_win_set_cursor(win, _draft.cursor)
end

return M
