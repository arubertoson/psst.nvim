pcall(vim.cmd, "packadd mini.nvim")

local MiniTest = _G.MiniTest or require("mini.test")
if not _G.MiniTest then MiniTest.setup({ silent = true }) end

local pi_dispatch = require("psst.adapters.pi").dispatch

local function leave_visual_mode()
    local mode = vim.fn.mode()
    if mode == "v" or mode == "V" or mode == "\22" then
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("<Esc>", true, false, true),
            "x",
            false
        )
    end
end

local function unload_psst()
    local float = package.loaded["psst.channels.float"]
    if float then pcall(float.close) end
    local agent = package.loaded.psst
    if agent then agent.setup({ keymaps = { global = false } }) end

    local modules = {}
    for name in pairs(package.loaded) do
        if name == "psst" or name:match("^psst%.") then modules[#modules + 1] = name end
    end
    for _, name in ipairs(modules) do
        package.loaded[name] = nil
    end
end

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            leave_visual_mode()
            unload_psst()
            vim.cmd("silent! %bwipeout!")
            vim.cmd("enew!")
            vim.bo.swapfile = false
        end,
        post_case = function()
            leave_visual_mode()
            unload_psst()
            vim.cmd("silent! %bwipeout!")
        end,
    },
})

local function current_invocation(selection)
    local buf = vim.api.nvim_get_current_buf()
    return {
        cwd = vim.fn.getcwd(),
        bufnr = buf,
        path = vim.api.nvim_buf_get_name(buf),
        filetype = vim.bo[buf].filetype,
        winid = vim.api.nvim_get_current_win(),
        cursor = vim.api.nvim_win_get_cursor(0),
        selection = selection,
    }
end

local function completed_transport(message, answer)
    return {
        message = message,
        label = "test",
        dispatch = pi_dispatch,
        run = function(_, on_event, on_exit)
            on_event({
                type = "message_update",
                assistantMessageEvent = {
                    type = "text_delta",
                    delta = answer,
                },
            })
            on_exit({ code = 0, stderr = "" })
        end,
    }
end

local function completed_float_transport(response, message, answer)
    local transport = completed_transport(message, answer)
    transport.response = response
    return transport
end

local function float_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(win)
        if config.relative == "editor" and config.zindex == 49 then return win end
    end
    return nil
end

local function float_lines()
    local win = float_window()
    if not win then return nil end
    return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
end

local function text_event(delta)
    return {
        type = "message_update",
        assistantMessageEvent = {
            type = "text_delta",
            delta = delta,
        },
    }
end

T["harness"] = MiniTest.new_set()

T["harness"]["malformed JSON output fails the process result"] = function()
    local completed
    require("psst.process").json({
        executable = "sh",
        args = { "-c", "printf 'not-json\\n'" },
        stdin = "",
        on_event = function() error("malformed output must not emit an event") end,
        on_exit = function(result) completed = result end,
    })

    MiniTest.expect.equality(vim.wait(1000, function() return completed ~= nil end), true)
    MiniTest.expect.equality(completed.code, 1)
    MiniTest.expect.equality(
        require("psst.process").stderr_summary(completed),
        "Harness emitted malformed JSON"
    )
end

T["harness"]["config rejects malformed and unknown options"] = function()
    local config = require("psst.config")
    local invalid = {
        { opts = { executable = "" }, message = "executable" },
        { opts = { typo = true }, message = "unknown psst config option" },
        { opts = { keymaps = true }, message = "psst keymaps config must be a table" },
        {
            opts = { keymaps = { global = "yes" } },
            message = "psst keymaps global must be a boolean",
        },
        { opts = { keymaps = { typo = true } }, message = "unknown psst keymaps option" },
    }

    for _, case in ipairs(invalid) do
        local ok, err = pcall(config.setup, case.opts)
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.equality(tostring(err):find(case.message, 1, true) ~= nil, true)
    end
end

T["harness"]["requests reject malformed fields and collectors"] = function()
    local agent = require("psst")
    local destination = require("psst.channels").DESTINATION.FLOAT
    local invalid = {
        { request = {}, message = "invalid agent destination" },
        {
            request = { destination = destination, typo = true },
            message = "unknown agent request field",
        },
    }

    for _, case in ipairs(invalid) do
        local ok, err = pcall(agent.send, case.request)
        MiniTest.expect.equality(ok, false)
        MiniTest.expect.equality(tostring(err):find(case.message, 1, true) ~= nil, true)
    end
end

T["harness"]["Pi adapter builds an inquiry command with an explicit session"] = function()
    local adapter = require("psst.adapters").get("pi")
    local command = adapter._command({
        executable = "pi-dev",
        adapter = "pi",
        session_dir = "/tmp/sessions",
        float = { side = "right", width = 60 },
    }, {
        destination = "float",
        preset = "review",
    }, {
        kind = "explicit",
        id = "session-id",
    }, "inquire")

    MiniTest.expect.equality(command, {
        "pi-dev",
        "--preset",
        "review",
        "--tools",
        "read,ffgrep,fffind",
        "--mode",
        "json",
        "--session-dir",
        "/tmp/sessions",
        "--session-id",
        "session-id",
    })
end

T["session"] = MiniTest.new_set()

T["session"]["working directory mismatch creates a session"] = function()
    local session = require("psst.session")
    local first, response = session.begin_read("/one", "pi", false)
    session.finish(response, "complete")
    local second = session.begin_read("/two", "pi", false)

    MiniTest.expect.equality(first ~= second, true)
    MiniTest.expect.equality(session.selection().session.cwd, "/two")
end

T["session"]["navigation stops at boundaries and restores response selection"] = function()
    local session = require("psst.session")
    local first, response = session.begin_read("/one", "pi", false)
    session.finish(response, "complete")
    local _, second_response = session.begin_read("/one", "pi", false)
    session.finish(second_response, "complete")

    MiniTest.expect.equality(session.navigate_response(1), false)
    MiniTest.expect.equality(session.navigate_response(-1), true)
    MiniTest.expect.equality(session.navigate_response(-1), false)

    local second_session, third_response = session.begin_read("/one", "pi", true)
    session.finish(third_response, "complete")
    MiniTest.expect.equality(session.navigate_session(1), false)
    MiniTest.expect.equality(session.navigate_session(-1), true)
    MiniTest.expect.equality(session.selection().session, first)
    MiniTest.expect.equality(session.selection().response_index, 1)

    session.navigate_response(1)
    session.navigate_session(1)
    MiniTest.expect.equality(session.selection().session, second_session)
    session.navigate_session(-1)
    MiniTest.expect.equality(session.selection().response_index, 2)
    MiniTest.expect.equality(session.navigate_session(-1), false)
end

T["context"] = MiniTest.new_set()

T["context"]["normal mode ignores stale visual marks"] = function()
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].filetype = "text"

    local source = {}
    for i = 1, 120 do
        source[i] = ("line %d"):format(i)
    end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, source)
    vim.fn.setpos("'<", { buf, 1, 1, 0 })
    vim.fn.setpos("'>", { buf, 1, 6, 0 })
    vim.api.nvim_win_set_cursor(0, { 100, 0 })

    local item = require("psst.collect.block").collect(current_invocation(nil))

    MiniTest.expect.equality(item.start_line, 50)
    MiniTest.expect.equality(item.end_line, 120)
end

T["context"]["explicit visual selection is collected exactly"] = function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "before", "selected text", "after" })

    local selection = {
        start_row = 1,
        start_col = 0,
        end_row = 1,
        end_col = 13,
    }
    local item = require("psst.collect.block").collect(current_invocation(selection))

    MiniTest.expect.equality(item.text, "selected text")
    MiniTest.expect.equality(item.start_line, 2)
    MiniTest.expect.equality(item.end_line, 2)
end

T["context"]["characterwise selection includes complete multibyte characters"] = function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "aé中z" })
    vim.fn.setpos("'<", { buf, 1, 2, 0 })
    vim.fn.setpos("'>", { buf, 1, 4, 0 })

    local invocation
    package.loaded["psst.prompt"] = {
        open = function(deps)
            invocation = deps.invocation
            return true
        end,
    }

    local opened = require("psst").prompt({ visual_mode = "v", collect = {} })

    MiniTest.expect.equality(opened, true)
    MiniTest.expect.equality(invocation.selection, {
        start_row = 0,
        start_col = 1,
        end_row = 0,
        end_col = 6,
    })
    MiniTest.expect.equality(require("psst.collect.block").collect(invocation).text, "é中")
end

T["context"]["blockwise selections are rejected at the prompt boundary"] = function()
    local opened = false
    package.loaded["psst.prompt"] = {
        open = function()
            opened = true
            return true
        end,
    }

    local notification
    local notify = vim.notify
    vim.notify = function(message, level) notification = { message, level } end
    local ok, result = pcall(require("psst").prompt, { visual_mode = "\22" })
    vim.notify = notify
    if not ok then error(result) end

    MiniTest.expect.equality(result, false)
    MiniTest.expect.equality(opened, false)
    MiniTest.expect.equality(notification, {
        "Agent prompts do not support blockwise selections",
        vim.log.levels.ERROR,
    })
end

T["context"]["diagnostic end columns are exclusive"] = function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "0123456789" })
    local namespace = vim.api.nvim_create_namespace("aru-agent-test-diagnostics")
    vim.diagnostic.set(namespace, buf, {
        {
            lnum = 0,
            col = 0,
            end_lnum = 0,
            end_col = 5,
            message = "before",
            severity = vim.diagnostic.severity.ERROR,
        },
        {
            lnum = 0,
            col = 5,
            end_lnum = 0,
            end_col = 10,
            message = "at cursor",
            severity = vim.diagnostic.severity.ERROR,
        },
    })
    vim.api.nvim_win_set_cursor(0, { 1, 5 })

    local item = require("psst.collect.diagnostic").collect(current_invocation(nil))

    MiniTest.expect.equality(item.text:find("message: at cursor", 1, true) ~= nil, true)
end

T["generate"] = MiniTest.new_set()

T["generate"]["normal mode inserts at the captured cursor"] = function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local  = true" })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })

    local ctx = { state = current_invocation(nil) }
    local transport = completed_transport("insert a name", "value")

    MiniTest.expect.equality(require("psst.channels.editor").send(transport, ctx), true)
    MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
        "local value = true",
    })
    MiniTest.expect.equality(vim.fn.mode(), "v")
end

T["generate"]["visual mode replaces and selects the captured range"] = function()
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "local old = true" })

    local selection = {
        start_row = 0,
        start_col = 6,
        end_row = 0,
        end_col = 9,
    }
    local ctx = { state = current_invocation(selection) }
    local transport = completed_transport("replace it", "new")

    MiniTest.expect.equality(require("psst.channels.editor").send(transport, ctx), true)
    MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), {
        "local new = true",
    })
    MiniTest.expect.equality(vim.fn.mode(), "v")

    leave_visual_mode()
    MiniTest.expect.equality(vim.fn.getpos("'<")[3], 7)
    MiniTest.expect.equality(vim.fn.getpos("'>")[3], 9)
end

T["generate"]["startup failure clears generation state"] = function()
    local buf = vim.api.nvim_get_current_buf()
    local editor = require("psst.channels.editor")
    local ok, err = pcall(editor.send, {
        message = "generate",
        label = "test",
        dispatch = pi_dispatch,
        run = function() error("failed to start") end,
    }, {
        state = current_invocation(nil),
    })

    MiniTest.expect.equality(ok, false)
    MiniTest.expect.equality(tostring(err):find("failed to start", 1, true) ~= nil, true)
    MiniTest.expect.equality(#vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}), 0)

    local sent = editor.send(completed_transport("retry", "recovered"), {
        state = current_invocation(nil),
    })
    MiniTest.expect.equality(sent, true)
    MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "recovered" })
end

T["generate"]["one-shot generation preserves read session history"] = function()
    local session = require("psst.session")
    local cwd = vim.fn.getcwd()
    local _, response = session.begin_read(cwd, "test", false)
    session.finish(response, "complete")

    local before = session.selection()
    local buf = vim.api.nvim_get_current_buf()
    local transport = completed_transport("insert a value", "generated")
    require("psst.channels.editor").send(transport, {
        state = current_invocation(nil),
    })

    local after = session.selection()
    MiniTest.expect.equality(after.session.id, before.session.id)
    MiniTest.expect.equality(after.response, before.response)
    MiniTest.expect.equality(vim.api.nvim_buf_get_lines(buf, 0, -1, false), { "generated" })
end

T["float"] = MiniTest.new_set()

T["float"]["side and width configure window geometry"] = function()
    local opened_layout
    require("psst.config").setup({
        float = {
            side = "left",
            width = 72,
            before_open = function(layout) opened_layout = layout end,
        },
    })

    local session = require("psst.session")
    local _, response = session.begin_read(vim.fn.getcwd(), "test", false)
    local float = require("psst.channels.float")
    float.send({
        message = "question",
        label = "test",
        response = response,
        dispatch = pi_dispatch,
        run = function() end,
    }, {})

    local float_config
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local win_config = vim.api.nvim_win_get_config(win)
        if win_config.relative == "editor" then
            float_config = win_config
            break
        end
    end

    MiniTest.expect.equality(opened_layout, { side = "left", width = 72 })
    MiniTest.expect.equality(float_config.width, 72)
    MiniTest.expect.equality(float_config.col, 3)
    float.close()
end

T["float"]["resize keeps the complete geometry on screen"] = function()
    require("psst.config").setup({ float = { side = "right", width = 72 } })

    local session = require("psst.session")
    local _, response = session.begin_read(vim.fn.getcwd(), "test", false)
    local float = require("psst.channels.float")
    float.send({
        message = "question",
        label = "test",
        response = response,
        dispatch = pi_dispatch,
        run = function() end,
    }, {})

    local original_columns = vim.o.columns
    local ok, err = xpcall(function()
        vim.o.columns = 50
        vim.api.nvim_exec_autocmds("VimResized", {})
        local float_config = vim.api.nvim_win_get_config(float_window())
        MiniTest.expect.equality(float_config.width, 42)
        MiniTest.expect.equality(float_config.col, 3)
    end, debug.traceback)
    float.close()
    vim.o.columns = original_columns
    if not ok then error(err) end
end

T["float"]["lifecycle hooks run once per visibility transition"] = function()
    local before_open = 0
    local after_close = 0
    require("psst.config").setup({
        float = {
            before_open = function() before_open = before_open + 1 end,
            after_close = function() after_close = after_close + 1 end,
        },
    })

    local float = require("psst.channels.float")
    local session = require("psst.session")
    local _, first = session.begin_read(vim.fn.getcwd(), "test", false)
    float.send(completed_float_transport(first, "question", "first"), {})
    local _, second = session.begin_read(vim.fn.getcwd(), "test", false)
    float.send(completed_float_transport(second, "question", "second"), {})
    MiniTest.expect.equality({ before_open, after_close }, { 1, 0 })

    float.close()
    MiniTest.expect.equality({ before_open, after_close }, { 1, 1 })

    float.restore()
    float.focus()
    vim.api.nvim_win_close(0, true)
    MiniTest.expect.equality({ before_open, after_close }, { 2, 2 })
end

T["float"]["focused mappings navigate responses and sessions without leaking"] = function()
    local session = require("psst.session")
    local float = require("psst.channels.float")
    local _, first = session.begin_read("/one", "pi", false)
    float.send(completed_float_transport(first, "first prompt", "first answer"), {})
    local _, second = session.begin_read("/one", "pi", false)
    float.send(completed_float_transport(second, "second prompt", "second answer"), {})
    local _, third = session.begin_read("/two", "pi", true)
    float.send(completed_float_transport(third, "third prompt", "third answer"), {})

    local source_buf = vim.api.nvim_get_current_buf()
    local win = float_window()
    local buf = vim.api.nvim_win_get_buf(win)
    MiniTest.expect.equality(float.is_visible(), true)
    MiniTest.expect.equality(vim.fn.maparg("[r", "n", false, true).buffer or 0, 0)
    for _, lhs in ipairs({
        "[r",
        "]r",
        "[s",
        "]s",
        "<M-u>",
        "<M-d>",
        "<C-u>",
        "<C-d>",
    }) do
        local found = false
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            if
                vim.api.nvim_replace_termcodes(map.lhs, true, false, true)
                == vim.api.nvim_replace_termcodes(lhs, true, false, true)
            then
                found = true
            end
        end
        if not found then error("missing float mapping: " .. lhs) end
    end
    for _, lhs in ipairs({ "<M-h>", "<M-l>", "<M-H>", "<M-L>" }) do
        for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
            MiniTest.expect.equality(mapping.lhs ~= lhs, true)
        end
    end
    vim.cmd("tabnew")
    MiniTest.expect.equality(float.is_visible(), false)
    vim.cmd("tabclose")
    MiniTest.expect.equality(float.is_visible(), true)

    float.focus()
    local function press(lhs)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "xt", false)
    end

    press("[s")
    MiniTest.expect.equality(session.selection().session_index, 1)
    MiniTest.expect.equality(session.selection().response_index, 2)
    MiniTest.expect.equality(float_lines(), { "second answer" })
    press("[r")
    MiniTest.expect.equality(session.selection().response_index, 1)
    press("]r")
    MiniTest.expect.equality(session.selection().response_index, 2)
    press("]s")
    MiniTest.expect.equality(session.selection().session_index, 2)
    press("[s")
    MiniTest.expect.equality(session.selection().session_index, 1)
    press("]s")
    MiniTest.expect.equality(session.selection().session_index, 2)

    float.close()
    MiniTest.expect.equality(float.is_visible(), false)
    MiniTest.expect.equality(vim.api.nvim_buf_is_valid(buf), false)
    MiniTest.expect.equality(vim.fn.maparg("[r", "n", false, true).buffer or 0, 0)
    MiniTest.expect.equality(vim.api.nvim_buf_is_valid(source_buf), true)
end

T["float"]["float navigation mappings can be disabled without losing close controls"] = function()
    local agent = require("psst")
    agent.setup({ keymaps = { global = false, float = false } })
    local session = require("psst.session")
    local float = require("psst.channels.float")
    local _, response = session.begin_read(vim.fn.getcwd(), "pi", false)
    float.send(completed_float_transport(response, "question", "answer"), {})
    local buf = vim.api.nvim_win_get_buf(float_window())
    local mapped = {}
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        mapped[mapping.lhs] = true
    end
    MiniTest.expect.equality(mapped["[r"], nil)
    MiniTest.expect.equality(mapped["<C-u>"], nil)
    MiniTest.expect.equality(mapped.q, true)
    MiniTest.expect.equality(mapped["<Esc>"], true)
end

T["float"]["scroll mappings move the focused float"] = function()
    local session = require("psst.session")
    local float = require("psst.channels.float")
    local _, response = session.begin_read(vim.fn.getcwd(), "pi", false)
    local lines = {}
    for i = 1, 100 do
        lines[i] = "line " .. i
    end
    float.send(completed_float_transport(response, "question", table.concat(lines, "\n")), {})
    local win = float_window()
    local source_win = vim.api.nvim_get_current_win()
    float.focus()
    local function press(lhs)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "xt", false)
    end
    local function topline()
        return vim.api.nvim_win_call(win, function() return vim.fn.winsaveview().topline end)
    end

    press("<M-d>")
    MiniTest.expect.equality(topline() > 1, true)
    press("<C-u>")
    MiniTest.expect.equality(topline(), 1)
    press("<C-d>")
    MiniTest.expect.equality(topline() > 1, true)
    press("<M-u>")
    MiniTest.expect.equality(topline(), 1)

    vim.api.nvim_set_current_win(source_win)
    require("psst").float.scroll("down")
    MiniTest.expect.equality(topline() > 1, true)
    MiniTest.expect.equality(vim.api.nvim_get_current_win(), source_win)
    require("psst").float.scroll("up")
    MiniTest.expect.equality(topline(), 1)

    local agent = require("psst")
    agent.setup({ keymaps = { global = true } })
    press("<M-d>")
    MiniTest.expect.equality(topline() > 1, true)
    press("<M-u>")
    MiniTest.expect.equality(topline(), 1)
    MiniTest.expect.equality(vim.api.nvim_get_current_win(), source_win)
    agent.setup({ keymaps = { global = false } })
end

T["float"]["default global mappings respect existing user keys"] = function()
    local agent = require("psst")
    local function global_map(lhs)
        for _, mapping in ipairs(vim.api.nvim_get_keymap("n")) do
            if mapping.lhs == lhs then return mapping end
        end
    end

    agent.setup()
    MiniTest.expect.equality(global_map("<M-l>").desc, "Psst: next response")
    agent.setup({ keymaps = { global = false } })
    MiniTest.expect.equality(global_map("<M-l>"), nil)
    local custom = function() end
    vim.keymap.set("n", "<M-h>", custom)
    agent.setup({ keymaps = { global = true } })
    MiniTest.expect.equality(global_map("<M-h>").callback, custom)
    MiniTest.expect.equality(global_map("<M-l>").desc, "Psst: next response")
    agent.setup({ keymaps = { global = true } })
    MiniTest.expect.equality(global_map("<M-h>").callback, custom)

    vim.keymap.set("n", "<M-l>", custom)
    agent.setup({ keymaps = { global = false } })
    MiniTest.expect.equality(global_map("<M-h>").callback, custom)
    MiniTest.expect.equality(global_map("<M-l>").callback, custom)
    MiniTest.expect.equality(global_map("<M-H>"), nil)
    vim.keymap.del("n", "<M-h>")
    vim.keymap.del("n", "<M-l>")
end

T["float"]["opted-in global navigation works from the editor and a closed float"] = function()
    local agent = require("psst")
    agent.setup({ keymaps = { global = true } })
    local session = require("psst.session")
    local float = require("psst.channels.float")
    local _, first = session.begin_read("/one", "pi", false)
    float.send(completed_float_transport(first, "first", "first answer"), {})
    local _, second = session.begin_read("/one", "pi", false)
    float.send(completed_float_transport(second, "second", "second answer"), {})
    local _, third = session.begin_read("/two", "pi", true)
    float.send(completed_float_transport(third, "third", "third answer"), {})
    local source_win = vim.api.nvim_get_current_win()
    local function press(lhs)
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "xt", false)
    end

    press("<M-H>")
    MiniTest.expect.equality(session.selection().session_index, 1)
    MiniTest.expect.equality(vim.api.nvim_get_current_win(), source_win)
    press("<M-h>")
    MiniTest.expect.equality(session.selection().response_index, 1)
    MiniTest.expect.equality(float_lines(), { "first answer" })
    float.close()
    press("<M-l>")
    MiniTest.expect.equality(session.selection().response_index, 2)
    MiniTest.expect.equality(float_lines(), { "second answer" })
    press("<M-L>")
    MiniTest.expect.equality(session.selection().session_index, 2)
    agent.setup({ keymaps = { global = false } })
end

T["float"]["navigation does not interrupt a background stream"] = function()
    local session = require("psst.session")
    local float = require("psst.channels.float")
    local _, first = session.begin_read("/one", "pi", false)
    float.send(completed_float_transport(first, "first prompt", "first answer"), {})

    local _, second = session.begin_read("/two", "pi", true)
    float.send(completed_float_transport(second, "second prompt", "second answer"), {})

    local _, streaming = session.begin_read("/two", "pi", false)
    local on_event
    local on_exit
    float.send({
        message = "third prompt",
        label = "pi",
        response = streaming,
        dispatch = pi_dispatch,
        run = function(_, event, exit)
            on_event = event
            on_exit = exit
        end,
    }, {})

    session.navigate_response(-1)
    float.show_selected()
    MiniTest.expect.equality(float_lines(), { "second answer" })
    MiniTest.expect.equality(
        vim.api.nvim_win_get_config(float_window()).title[1][1],
        " pi · S2/2 · R1/2 "
    )

    on_event(text_event("background output"))
    MiniTest.expect.equality(streaming.lines, { "background output" })
    MiniTest.expect.equality(float_lines(), { "second answer" })

    session.navigate_session(-1)
    float.show_selected()
    on_exit({ code = 0, stderr = "" })
    MiniTest.expect.equality(session.selection().session_index, 1)
    MiniTest.expect.equality(streaming.status, "complete")

    session.navigate_session(1)
    MiniTest.expect.equality(session.selection().response_index, 1)
    session.navigate_response(1)
    float.show_selected()
    MiniTest.expect.equality(float_lines(), { "background output" })
end

T["float"]["closing while streaming preserves output for restore"] = function()
    local session = require("psst.session")
    local float = require("psst.channels.float")
    local _, response = session.begin_read(vim.fn.getcwd(), "pi", false)
    local on_event
    local on_exit
    float.send({
        message = "question",
        label = "pi",
        response = response,
        dispatch = pi_dispatch,
        run = function(_, event, exit)
            on_event = event
            on_exit = exit
        end,
    }, {})

    float.close()
    on_event(text_event("received while closed"))
    MiniTest.expect.equality(float_window(), nil)
    MiniTest.expect.equality(response.lines, { "received while closed" })

    float.restore()
    MiniTest.expect.equality(float_lines(), { "received while closed" })
    on_exit({ code = 0, stderr = "" })
end

T["float"]["failed responses remain visible without rendering the prompt"] = function()
    local session = require("psst.session")
    local float = require("psst.channels.float")
    local _, response = session.begin_read(vim.fn.getcwd(), "pi", false)
    float.send({
        message = "prompt must not be rendered",
        label = "pi",
        response = response,
        dispatch = pi_dispatch,
        run = function(_, on_event, on_exit)
            on_event(text_event("partial"))
            on_exit({ code = 1, stderr = "failure details\nmore" })
        end,
    }, {})

    MiniTest.expect.equality(response.status, "error")
    MiniTest.expect.equality(float_lines(), { "partial", "[error: failure details]" })
end

T["facade"] = MiniTest.new_set()

T["facade"]["read requests reuse explicit identity unless forced new"] = function()
    local calls = {}
    require("psst.process").json = function(opts)
        calls[#calls + 1] = opts
        opts.on_exit({ code = 0, stderr = "" })
    end

    local channels = require("psst.channels")
    local agent = require("psst")
    local session_dir = vim.fn.tempname()
    agent.setup({ session_dir = session_dir })

    agent.send({
        destination = channels.DESTINATION.FLOAT,
        collect = {},
        prompt = "first",
    })
    agent.send({
        destination = channels.DESTINATION.FLOAT,
        collect = {},
        prompt = "continue",
    })
    agent.send({
        destination = channels.DESTINATION.FLOAT,
        force_new_session = true,
        collect = {},
        prompt = "new",
    })

    local function argument_value(call, name)
        for index, arg in ipairs(call.args) do
            if arg == name then return call.args[index + 1] end
        end
    end

    MiniTest.expect.equality(argument_value(calls[1], "--tools"), "read,ffgrep,fffind")
    MiniTest.expect.equality(
        argument_value(calls[1], "--session-id"),
        argument_value(calls[2], "--session-id")
    )
    MiniTest.expect.equality(
        argument_value(calls[2], "--session-id") ~= argument_value(calls[3], "--session-id"),
        true
    )
    MiniTest.expect.equality(require("psst.session").counts(), 2)
    pcall(vim.fs.rm, session_dir, { recursive = true })
end

T["facade"]["concurrent Read is rejected without starting a process"] = function()
    local calls = {}
    require("psst.process").json = function(opts) calls[#calls + 1] = opts end

    local channels = require("psst.channels")
    local agent = require("psst")
    local session_dir = vim.fn.tempname()
    agent.setup({ session_dir = session_dir })

    local first = agent.send({
        destination = channels.DESTINATION.FLOAT,
        collect = {},
        prompt = "first",
    })
    local second = agent.send({
        destination = channels.DESTINATION.FLOAT,
        collect = {},
        prompt = "second",
    })

    MiniTest.expect.equality(first, true)
    MiniTest.expect.equality(second, false)
    MiniTest.expect.equality(#calls, 1)
    MiniTest.expect.equality(require("psst.session").counts(), 1)
    pcall(vim.fs.rm, session_dir, { recursive = true })
end

T["facade"]["Generate does not create or select Agent Sessions"] = function()
    local process_opts
    require("psst.process").json = function(opts)
        process_opts = opts
        opts.on_event(text_event("generated"))
        opts.on_exit({ code = 0, stderr = "" })
    end

    local channels = require("psst.channels")
    local agent = require("psst")
    local session_dir = vim.fn.tempname()
    agent.setup({ session_dir = session_dir })
    local sent = agent.send({
        destination = channels.DESTINATION.EDITOR,
        collect = {},
        prompt = "generate",
    })

    MiniTest.expect.equality(sent, true)
    MiniTest.expect.equality(vim.tbl_contains(process_opts.args, "--tools"), false)
    MiniTest.expect.equality({ require("psst.session").counts() }, { 0, 0 })
    MiniTest.expect.equality(vim.uv.fs_stat(session_dir), nil)
end

T["clear"] = MiniTest.new_set()

T["clear"]["removes disk and memory state and closes the float"] = function()
    local session_dir = vim.fn.tempname()
    vim.fs.mkdir(session_dir, { parents = true })
    vim.fn.writefile({ "session" }, session_dir .. "/session.json")

    local agent = require("psst")
    agent.setup({ session_dir = session_dir })
    local session = require("psst.session")
    local _, response = session.begin_read(vim.fn.getcwd(), "pi", false)
    require("psst.channels.float").send(
        completed_float_transport(response, "question", "answer"),
        {}
    )

    local notification
    local notify = vim.notify
    vim.notify = function(message) notification = message end
    local ok, cleared = pcall(agent.sessions_clear)
    vim.notify = notify
    if not ok then error(cleared) end

    MiniTest.expect.equality(cleared, true)
    MiniTest.expect.equality(vim.uv.fs_stat(session_dir), nil)
    MiniTest.expect.equality({ session.counts() }, { 0, 0 })
    MiniTest.expect.equality(float_window(), nil)
    MiniTest.expect.equality(notification, "Cleared 1 agent sessions and 1 responses")
    MiniTest.expect.equality(vim.fn.exists(":PsstSessionsClear"), 2)
end

T["clear"]["disk failure preserves memory and float visibility"] = function()
    local session_dir = vim.fn.tempname()
    vim.fs.mkdir(session_dir, { parents = true })
    local agent = require("psst")
    agent.setup({ session_dir = session_dir })
    local session = require("psst.session")
    local _, response = session.begin_read(vim.fn.getcwd(), "pi", false)
    require("psst.channels.float").send(
        completed_float_transport(response, "question", "answer"),
        {}
    )
    local win = float_window()

    local rm = vim.fs.rm
    vim.fs.rm = function() error("EACCES: denied") end
    local ok, cleared = pcall(agent.sessions_clear)
    vim.fs.rm = rm
    pcall(vim.fs.rm, session_dir, { recursive = true })
    if not ok then error(cleared) end

    MiniTest.expect.equality(cleared, false)
    MiniTest.expect.equality({ session.counts() }, { 1, 1 })
    MiniTest.expect.equality(vim.api.nvim_win_is_valid(win), true)
end

T["clear"]["streaming refusal preserves all state"] = function()
    local session_dir = vim.fn.tempname()
    vim.fs.mkdir(session_dir, { parents = true })
    local agent = require("psst")
    agent.setup({ session_dir = session_dir })
    local session = require("psst.session")
    local _, response = session.begin_read(vim.fn.getcwd(), "pi", false)
    local finish
    require("psst.channels.float").send({
        message = "question",
        label = "pi",
        response = response,
        dispatch = pi_dispatch,
        run = function(_, _, on_exit) finish = on_exit end,
    }, {})
    local win = float_window()

    local removed = false
    local rm = vim.fs.rm
    vim.fs.rm = function()
        removed = true
        return rm(session_dir, { recursive = true })
    end
    local ok, cleared = pcall(agent.sessions_clear)
    vim.fs.rm = rm
    if not ok then error(cleared) end

    MiniTest.expect.equality(cleared, false)
    MiniTest.expect.equality(removed, false)
    MiniTest.expect.equality(response.status, "streaming")
    MiniTest.expect.equality(vim.api.nvim_win_is_valid(win), true)
    finish({ code = 0, stderr = "" })
    pcall(vim.fs.rm, session_dir, { recursive = true })
end

return T
