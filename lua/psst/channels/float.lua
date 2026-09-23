---@module "psst.channels.float"
---Streams Read output into Responses and renders the selected Response in a float.

local M = {}

local logger = require("psst.log")
local config = require("psst.config")
local constants = require("psst.constants")
local line_acc = require("psst.lines")
local process = require("psst.process")
local progress = require("psst.progress")
local session = require("psst.session")
local ui = require("psst.ui")

---@class Psst.channels.float.WindowState
---@field buf integer
---@field win integer
---@field augroup integer
---@field user_scrolled boolean
---@field layout Psst.config.FloatLayout

---@class Psst.channels.float.StreamState: Psst.progress.State
---@field response Psst.Response
---@field answer { lines: string[], pending: string }

local markview_autocmds_ready = false

---@type Psst.channels.float.WindowState|nil
local _window = nil

---@type Psst.channels.float.StreamState|nil
local _stream = nil

---@param name "before_open"|"after_close"
---@param layout Psst.config.FloatLayout
local function run_lifecycle_hook(name, layout)
    local hook = config.get().float[name]
    if not hook then return end

    local ok, err = pcall(hook, layout)
    if not ok then logger.error("Float hook failed", name, err) end
end

---@return table|nil
local function markview_actions()
    if not markview_autocmds_ready then
        local ok, autocmds = pcall(require, "markview.autocmds")
        if not ok then return nil end
        local setup_ok = pcall(autocmds.setup)
        if not setup_ok then return nil end
        markview_autocmds_ready = true
    end

    local ok, actions = pcall(require, "markview.actions")
    if not ok then return nil end
    return actions
end

---@param buf integer
local function attach_markview(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local actions = markview_actions()
    if not actions then return end
    pcall(actions.attach, buf, { enable = true, hybrid_mode = false })
end

---@param buf integer
local function render_markview(buf)
    if not vim.api.nvim_buf_is_valid(buf) then return end
    local actions = markview_actions()
    if not actions then return end
    pcall(actions.render, buf, { enable = true, hybrid_mode = false })
end

local function stop_spinner()
    if _stream then progress.stop(_stream) end
end

local function close_float()
    if not _window then return end
    local state = _window
    _window = nil
    stop_spinner()
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    ui.close_win_buf(state.win, state.buf)
    run_lifecycle_hook("after_close", state.layout)
end

local function float_width()
    local layout = constants.UI.READ_FLOAT
    local available = math.max(1, vim.o.columns - layout.SIDE_MARGIN * 2 - layout.BORDER_COLUMNS)
    return math.min(config.get().float.width, available)
end

---@param width integer
local function float_col(width)
    local layout = constants.UI.READ_FLOAT
    if config.get().float.side == "left" then return layout.SIDE_MARGIN end
    return math.max(0, vim.o.columns - width - layout.SIDE_MARGIN - layout.BORDER_COLUMNS)
end

local function max_height()
    local layout = constants.UI.READ_FLOAT
    local available = math.max(
        1,
        vim.o.lines - vim.o.cmdheight - layout.ROW - layout.BOTTOM_MARGIN - layout.BORDER_ROWS
    )
    return math.max(1, math.floor(available * layout.HEIGHT_RATIO))
end

---@param buf integer
---@param width integer
local function estimated_rows(buf, width)
    local rows = 0
    for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
        rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
    end
    return math.max(1, rows)
end

---@param state Psst.channels.float.WindowState
local function content_rows(state)
    if vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_win_text_height then
        local ok, height =
            pcall(vim.api.nvim_win_text_height, state.win, { start_row = 0, end_row = -1 })
        if ok and type(height) == "table" and type(height.all) == "number" then
            return math.max(1, height.all)
        end
    end

    return estimated_rows(state.buf, state.layout.width)
end

---@param state Psst.channels.float.WindowState
local function anchor_top(state)
    if not vim.api.nvim_win_is_valid(state.win) then return end
    pcall(vim.api.nvim_win_set_cursor, state.win, { 1, 0 })
end

---@param state Psst.channels.float.WindowState
local function resize(state)
    if not vim.api.nvim_win_is_valid(state.win) then return end

    local width = float_width()
    state.layout.width = width
    vim.api.nvim_win_set_config(state.win, {
        relative = "editor",
        row = constants.UI.READ_FLOAT.ROW,
        col = float_col(width),
        width = width,
    })

    local height = math.min(content_rows(state), max_height())
    vim.api.nvim_win_set_config(state.win, { height = height })
    if not state.user_scrolled then anchor_top(state) end
end

---@return string
local function title()
    local selected = session.selection()
    if not selected then error("Cannot title a response float without a selection") end

    local prefix = (" %s · S%d/%d · R%d/%d"):format(
        selected.response.label,
        selected.session_index,
        selected.session_count,
        selected.response_index,
        selected.response_count
    )
    if _stream and selected.response == _stream.response then
        return ("%s · %s %s "):format(prefix, progress.frame(_stream), _stream.phrase)
    end
    return prefix .. " "
end

local function refresh_title()
    if _window and vim.api.nvim_win_is_valid(_window.win) then
        vim.api.nvim_win_set_config(_window.win, { title = title() })
    end
end

local function sync_spinner()
    if not _stream then return end

    if _window and session.is_selected(_stream.response) then
        if _stream.spinner_timer then return end
        local active = _stream
        progress.start(active, {
            is_current = function()
                return _stream == active
                    and _window ~= nil
                    and session.is_selected(active.response)
            end,
            refresh = refresh_title,
        })
    else
        progress.stop(_stream)
    end
end

---@param buf integer
---@param lines string[]
local function set_lines(buf, lines)
    if not vim.api.nvim_buf_is_valid(buf) then return end

    vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
end

---@param state Psst.channels.float.WindowState
---@param direction "down"|"up"
local function scroll(state, direction)
    if not vim.api.nvim_win_is_valid(state.win) then return end
    if not vim.api.nvim_buf_is_valid(state.buf) then return end

    local selected = session.selection()
    if selected and selected.response.status == "streaming" then return end

    local win_height = vim.api.nvim_win_get_height(state.win)
    local amount = vim.v.count > 0 and vim.v.count or math.max(1, math.floor(win_height / 2))
    local key = direction == "down" and "<C-e>" or "<C-y>"
    local scroll_key = vim.api.nvim_replace_termcodes(key, true, false, true)

    vim.api.nvim_win_call(state.win, function()
        vim.cmd("normal! " .. amount .. scroll_key)
        local view = vim.fn.winsaveview()
        state.user_scrolled = view.topline > 1 or (view.skipcol or 0) > 0
    end)
end

---@param state Psst.channels.float.WindowState
local function install_keymaps(state)
    local map_opts = { buffer = state.buf, silent = true, nowait = true }
    for _, mapping in ipairs({
        { lhs = "<C-d>", direction = "down" },
        { lhs = "<M-d>", direction = "down" },
        { lhs = "<C-u>", direction = "up" },
        { lhs = "<M-u>", direction = "up" },
    }) do
        local direction = mapping.direction
        for _, mode in ipairs({ "n", "i" }) do
            vim.keymap.set(mode, mapping.lhs, function()
                local scroll_current = function()
                    if _window == state then scroll(state, direction) end
                end
                if mode == "i" then
                    vim.schedule(scroll_current)
                else
                    scroll_current()
                end
            end, vim.tbl_extend(
                "force",
                map_opts,
                { desc = "Scroll float " .. direction }
            ))
        end
    end

    for _, mapping in ipairs({
        {
            lhs = "[r",
            navigate = session.navigate_response,
            delta = -1,
            desc = "Previous response",
        },
        { lhs = "]r", navigate = session.navigate_response, delta = 1, desc = "Next response" },
        { lhs = "[s", navigate = session.navigate_session, delta = -1, desc = "Previous session" },
        { lhs = "]s", navigate = session.navigate_session, delta = 1, desc = "Next session" },
    }) do
        vim.keymap.set("n", mapping.lhs, function()
            if _window == state and mapping.navigate(mapping.delta) then M.show_selected() end
        end, vim.tbl_extend("force", map_opts, { desc = mapping.desc }))
    end
end

---@param lines string[]
---@return Psst.channels.float.WindowState
local function create_float_window(lines)
    local buf = ui.create_scratch_buf({
        filetype = constants.UI.FILETYPE_MARKDOWN,
        modifiable = false,
        lines = lines,
    })

    local ui_layout = constants.UI.READ_FLOAT
    local float_opts = config.get().float
    local width = float_width()
    local layout = { side = float_opts.side, width = width }
    local height = math.min(estimated_rows(buf, width), max_height())

    run_lifecycle_hook("before_open", layout)
    local ok, win = pcall(vim.api.nvim_open_win, buf, false, {
        relative = "editor",
        row = ui_layout.ROW,
        col = float_col(width),
        width = width,
        height = math.max(1, height),
        style = constants.UI.STYLE_MINIMAL,
        border = constants.UI.BORDER_ROUNDED,
        title = " agent ",
        title_pos = constants.UI.TITLE_POS_LEFT,
        zindex = ui_layout.ZINDEX,
    })
    if not ok then
        run_lifecycle_hook("after_close", layout)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        error(win)
    end
    ui.apply_win_options(win, {
        wrap = true,
        linebreak = true,
        breakindent = true,
        smoothscroll = true,
        cursorline = false,
        winhl = "CursorLine:Normal",
        scrolloff = 0,
    })

    local augroup = vim.api.nvim_create_augroup(constants.AUGROUP.READ_FLOAT, { clear = true })
    ---@type Psst.channels.float.WindowState
    local state = {
        buf = buf,
        win = win,
        augroup = augroup,
        user_scrolled = false,
        layout = layout,
    }
    _window = state

    vim.api.nvim_create_autocmd("WinClosed", {
        group = augroup,
        pattern = tostring(win),
        callback = function()
            if _window ~= state then return end
            _window = nil
            stop_spinner()
            pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
            run_lifecycle_hook("after_close", state.layout)
        end,
    })
    vim.api.nvim_create_autocmd("VimResized", {
        group = augroup,
        callback = function()
            if _window == state then resize(state) end
        end,
    })
    if config.get().keymaps.float then install_keymaps(state) end

    local map_opts = { buffer = buf, silent = true, nowait = true }
    vim.keymap.set("n", "q", close_float, map_opts)
    vim.keymap.set("n", "<Esc>", close_float, map_opts)

    attach_markview(buf)
    render_markview(buf)
    refresh_title()
    resize(state)
    sync_spinner()

    return state
end

---@return Psst.channels.float.WindowState|nil
function M.show_selected()
    local selected = session.selection()
    if not selected then return nil end

    local state = _window
    if state and vim.api.nvim_win_is_valid(state.win) and vim.api.nvim_buf_is_valid(state.buf) then
        stop_spinner()
        state.user_scrolled = false
        set_lines(state.buf, selected.response.lines)
        render_markview(state.buf)
        refresh_title()
        resize(state)
        sync_spinner()
        return state
    end

    return create_float_window(selected.response.lines)
end

---@param active Psst.channels.float.StreamState
---@return string[]
local function streamed_lines(active)
    local result = {}
    vim.list_extend(result, active.answer.lines)
    if active.answer.pending ~= "" then result[#result + 1] = active.answer.pending end
    if #result == 0 then result[1] = "" end
    return result
end

---@param active Psst.channels.float.StreamState
local function save_stream(active)
    active.response.lines = streamed_lines(active)
    if not session.is_selected(active.response) or not _window then return end

    set_lines(_window.buf, active.response.lines)
    render_markview(_window.buf)
    resize(_window)
end

---@param active Psst.channels.float.StreamState
---@param delta string
local function append(active, delta)
    line_acc.push(active.answer, delta)
    save_stream(active)
end

---@param active Psst.channels.float.StreamState
---@param status "complete"|"error"
local function finish(active, status)
    line_acc.flush(active.answer)
    save_stream(active)
    session.finish(active.response, status)
    progress.stop(active)
    _stream = nil
    if session.is_selected(active.response) and _window then
        refresh_title()
        resize(_window)
    end
end

---@param transport Psst.channels.Transport
---@param _ctx Psst.ConfigState|nil
---@return boolean
function M.send(transport, _ctx)
    if _stream then
        vim.notify("An agent response is already streaming", vim.log.levels.WARN)
        return false
    end
    if not transport.response then error("Float transport requires an owning Response") end
    if transport.response.status ~= "streaming" then
        error("Float transport Response must be streaming")
    end

    ---@type Psst.channels.float.StreamState
    local active = {
        response = transport.response,
        answer = { lines = {}, pending = "" },
    }
    progress.init(active)
    _stream = active

    logger.debug("Sending float channel response", transport.message)
    local ok, err = pcall(function()
        M.show_selected()
        transport.run(transport.message, function(event)
            if _stream ~= active then return end
            transport.dispatch(event, {
                on_thinking = function()
                    if progress.update_phrase(active) and session.is_selected(active.response) then
                        refresh_title()
                    end
                end,
                on_text = function(delta) append(active, delta) end,
            })
        end, function(result)
            if _stream ~= active then return end
            if result.code ~= 0 then
                local err_line = process.stderr_summary(result)
                logger.error("Float channel failed", result.code, err_line)
                append(active, "\n[error: " .. err_line .. "]")
                finish(active, "error")
                return
            end
            finish(active, "complete")
        end)
    end)

    if not ok then
        local err_line = tostring(err):match("[^\n]+") or tostring(err)
        logger.error("Float channel failed to start", err_line)
        append(active, "\n[error: " .. err_line .. "]")
        finish(active, "error")
        error(err)
    end

    return true
end

function M.restore()
    if not session.selection() then
        logger.info("No previous float response to restore")
        vim.notify("No response available to restore", vim.log.levels.INFO)
        return
    end
    M.show_selected()
end

function M.is_visible()
    return _window ~= nil
        and vim.api.nvim_win_is_valid(_window.win)
        and vim.api.nvim_win_get_buf(_window.win) == _window.buf
        and vim.api.nvim_win_get_tabpage(_window.win) == vim.api.nvim_get_current_tabpage()
end

function M.focus()
    if _window and vim.api.nvim_win_is_valid(_window.win) then
        if vim.api.nvim_get_current_win() == _window.win then
            vim.cmd("wincmd p")
        else
            vim.api.nvim_set_current_win(_window.win)
        end
    else
        M.restore()
    end
end

---@param direction "down"|"up"
function M.scroll(direction)
    if _window then scroll(_window, direction) end
end

function M.close() close_float() end

return M
