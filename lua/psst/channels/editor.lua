---@module "psst.channels.editor"
---Collects streamed agent output for code generation and applies the completed
---answer at the original cursor or selection. This channel owns generation progress,
---JSON event processing, final buffer replacement, and result selection.

local M = {}

local logger = require("psst.log")
local constants = require("psst.constants")
local lines = require("psst.lines")
local progress = require("psst.progress")
local process = require("psst.process")

local INSERT_SYSTEM_PROMPT = [[You are a code generation assistant embedded in a text editor.
Reply ONLY with the code that should be inserted at the cursor position.
Do NOT include any explanation, markdown fences, or prose.
Do NOT repeat code that already exists around the cursor.
Output raw code only.]]

local REPLACE_SYSTEM_PROMPT = [[You are a code generation assistant embedded in a text editor.
Reply ONLY with the replacement code for the selected block.
Do NOT include any explanation, markdown fences, or prose.
Output raw code only.]]

---@class Psst.channels.editor.State: Psst.progress.State
---@field buf integer
---@field win integer
---@field start_row integer
---@field start_col integer
---@field end_row integer
---@field end_col integer
---@field ns integer
---@field progress_id integer|nil
---@field process vim.SystemObj|nil
---@field answer { lines: string[], pending: string }

---@type Psst.channels.editor.State|nil
local _state = nil

---@param state Psst.channels.editor.State
local function clear_progress(state)
    if state.progress_id then
        pcall(vim.api.nvim_buf_del_extmark, state.buf, state.ns, state.progress_id)
        state.progress_id = nil
    end
end

---@param state Psst.channels.editor.State
local function refresh_progress(state)
    if not vim.api.nvim_buf_is_valid(state.buf) then return end

    local text = " " .. progress.frame(state) .. " " .. state.phrase
    local opts = {
        id = state.progress_id,
        virt_lines = { { { text, constants.UI.HIGHLIGHT_COMMENT } } },
        virt_lines_above = true,
        priority = 200,
    }
    if state.start_row ~= state.end_row or state.start_col ~= state.end_col then
        opts.end_row = state.end_row
        opts.end_col = state.end_col
        opts.hl_group = "Visual"
    end

    state.progress_id =
        vim.api.nvim_buf_set_extmark(state.buf, state.ns, state.start_row, state.start_col, opts)
end

---@param state Psst.channels.editor.State
local function start_spinner(state)
    progress.start(state, {
        is_current = function() return _state == state end,
        refresh = function() refresh_progress(state) end,
    })
end

---@param state Psst.channels.editor.State
local function stop_spinner(state) progress.stop(state) end

local function cancel_active()
    if not _state then return end
    local state = _state
    _state = nil
    stop_spinner(state)
    clear_progress(state)
    if state.process then pcall(state.process.kill, state.process, 15) end
end

---@param state Psst.channels.editor.State
---@param answer_lines string[]
local function select_answer(state, answer_lines)
    local end_row = state.start_row + #answer_lines - 1
    local end_col = #answer_lines == 1 and state.start_col + #answer_lines[1]
        or #answer_lines[#answer_lines]
    if end_row == state.start_row and end_col == state.start_col then return end

    vim.fn.setpos("'<", { state.buf, state.start_row + 1, state.start_col + 1, 0 })
    vim.fn.setpos("'>", { state.buf, end_row + 1, math.max(1, end_col), 0 })

    if
        vim.api.nvim_win_is_valid(state.win)
        and vim.api.nvim_win_get_buf(state.win) == state.buf
        and vim.api.nvim_get_current_win() == state.win
    then
        vim.api.nvim_win_call(state.win, function()
            vim.api.nvim_win_set_cursor(state.win, { state.start_row + 1, state.start_col })
            vim.cmd("normal! v")
            vim.api.nvim_win_set_cursor(state.win, { end_row + 1, math.max(0, end_col - 1) })
        end)
    end
end

---@param state Psst.channels.editor.State
local function insert_answer(state)
    clear_progress(state)
    if not vim.api.nvim_buf_is_valid(state.buf) then return end

    local answer_lines = lines.flush(state.answer)
    if vim.tbl_isempty(answer_lines) then return end

    vim.api.nvim_buf_set_text(
        state.buf,
        state.start_row,
        state.start_col,
        state.end_row,
        state.end_col,
        answer_lines
    )
    select_answer(state, answer_lines)
end

---@param transport Psst.channels.Transport
---@param ctx Psst.ConfigState
---@return boolean
function M.send(transport, ctx)
    local inv = ctx.state
    local buf = inv.bufnr
    if not vim.api.nvim_buf_is_valid(buf) then return false end

    local selection = inv.selection
    local start_row = selection and selection.start_row or inv.cursor[1] - 1
    local start_col = selection and selection.start_col or inv.cursor[2]
    local end_row = selection and selection.end_row or start_row
    local end_col = selection and selection.end_col or start_col

    cancel_active()

    ---@type Psst.channels.editor.State
    local state = {
        buf = buf,
        win = inv.winid,
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
        ns = vim.api.nvim_create_namespace(constants.NAMESPACE.EDITOR),
        progress_id = nil,
        process = nil,
        answer = { lines = {}, pending = "" },
    }
    progress.init(state)
    _state = state

    local system_prompt = selection and REPLACE_SYSTEM_PROMPT or INSERT_SYSTEM_PROMPT
    local stdin = transport.message == "" and system_prompt
        or system_prompt .. "\n\nUser request: " .. transport.message
    logger.info("Sending editor channel request", start_row, start_col, stdin)

    refresh_progress(state)
    start_spinner(state)

    local ok, process_or_error = pcall(transport.run, stdin, function(event)
        if _state ~= state then return end
        transport.dispatch(event, {
            on_thinking = function()
                if progress.update_phrase(state) then refresh_progress(state) end
            end,
            on_text = function(delta) lines.push(state.answer, delta) end,
        })
    end, function(result)
        if _state ~= state then return end
        state.process = nil
        _state = nil
        stop_spinner(state)

        if result.code ~= 0 then
            local error_message = process.stderr_summary(result)
            logger.error("Editor channel failed", result.code, error_message)
            vim.notify("Editor channel failed: " .. error_message, vim.log.levels.ERROR)
            clear_progress(state)
            return
        end

        insert_answer(state)
    end)

    if not ok then
        if _state == state then
            _state = nil
            stop_spinner(state)
            clear_progress(state)
        end
        error(process_or_error, 0)
    end
    if _state == state then state.process = process_or_error end

    return true
end

return M
