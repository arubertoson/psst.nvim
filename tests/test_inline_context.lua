pcall(vim.cmd, "packadd mini.nvim")
pcall(vim.cmd, "packadd nvim-treesitter-textobjects")

local MiniTest = _G.MiniTest or require("mini.test")
if not _G.MiniTest then MiniTest.setup({ silent = true }) end

local root
local invocation_buf

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            package.loaded["psst.context"] = nil
            root = vim.fn.tempname()
            vim.fs.mkdir(vim.fs.joinpath(root, "lua"), { parents = true })
            vim.fn.writefile({
                "local M = {}",
                "",
                "function M.send(value)",
                "    return value",
                "end",
                "",
                "return M",
            }, vim.fs.joinpath(root, "lua", "agent.lua"))
            vim.cmd("enew!")
            invocation_buf = vim.api.nvim_get_current_buf()
        end,
        post_case = function()
            vim.cmd("silent! %bwipeout!")
            vim.fn.delete(root, "rf")
        end,
    },
})

T["reference parser"] = MiniTest.new_set()

T["reference parser"]["recognizes every form with prose boundaries"] = function()
    local parser = require("psst.reference")
    local refs = parser.parse(
        "Compare `@lua/agent.lua#M::send` with (@lua/agent.lua:2-4), @#send and @lua/agent.lua.",
        nil
    )

    MiniTest.expect.equality(vim.tbl_map(function(ref) return ref.raw end, refs), {
        "@lua/agent.lua#M::send",
        "@lua/agent.lua:2-4",
        "@#send",
        "@lua/agent.lua",
    })
    MiniTest.expect.equality(refs[1].selector, { kind = "symbol", name = "M::send" })
    MiniTest.expect.equality(refs[2].selector, {
        kind = "lines",
        start_line = 2,
        end_line = 4,
    })
end

T["reference parser"]["ignores email addresses"] = function()
    local refs = require("psst.reference").parse("mail dev@example.com about @lua/agent.lua", nil)
    MiniTest.expect.equality(#refs, 1)
    MiniTest.expect.equality(refs[1].raw, "@lua/agent.lua")
end

T["reference parser"]["uses the cursor to classify incomplete syntax"] = function()
    local parser = require("psst.reference")
    local incomplete = "@lua/agent.lua:2-"
    local editing = parser.parse(incomplete, { 0, #incomplete })[1]
    local left = parser.parse(incomplete .. " next", { 0, #incomplete + 5 })[1]

    MiniTest.expect.equality(editing.state, "editing")
    MiniTest.expect.equality(left.state, "unresolved")
end

T["context resolver"] = MiniTest.new_set()

local function resolve(text, cursor)
    return require("psst.context").resolve(text, cursor, root, invocation_buf)
end

T["context resolver"]["resolves whole files and inclusive ranges"] = function()
    local resolved = resolve("@lua/agent.lua @lua/agent.lua:3-5", nil)

    MiniTest.expect.equality(resolved.references[1].state, "resolved")
    MiniTest.expect.equality(resolved.context[1].whole_file, true)
    MiniTest.expect.equality(
        resolved.context[2].text,
        "function M.send(value)\n    return value\nend"
    )
    MiniTest.expect.equality(
        { resolved.context[2].start_line, resolved.context[2].end_line },
        { 3, 5 }
    )
end

T["context resolver"]["loaded unsaved contents win over disk"] = function()
    local path = vim.fs.joinpath(root, "lua", "agent.lua")
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved", "contents" })

    local resolved = resolve("@lua/agent.lua", nil)
    MiniTest.expect.equality(resolved.context[1].text, "unsaved\ncontents")
end

T["context resolver"]["editing a resolved file into a selector drops stale context"] = function()
    local whole = resolve("@lua/agent.lua", { 0, 14 })
    local editing = resolve("@lua/agent.lua#", { 0, 15 })

    MiniTest.expect.equality(whole.references[1].state, "resolved")
    MiniTest.expect.equality(editing.references[1].state, "editing")
    MiniTest.expect.equality(#editing.context, 0)
end

T["context resolver"]["invalid ranges are unresolved even under the cursor"] = function()
    local reversed = resolve("@lua/agent.lua:5-2", { 0, 18 })
    local outside = resolve("@lua/agent.lua:1-99", { 0, 19 })

    MiniTest.expect.equality(reversed.references[1].state, "unresolved")
    MiniTest.expect.equality(outside.references[1].state, "unresolved")
end

T["context resolver"]["resolves file and invocation-buffer symbols"] = function()
    local path = vim.fs.joinpath(root, "lua", "agent.lua")
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].filetype = "lua"
    invocation_buf = bufnr

    local resolved = resolve("@lua/agent.lua#M.send @#M.send", nil)
    MiniTest.expect.equality(
        { resolved.references[1].state, resolved.references[2].state },
        { "resolved", "resolved" }
    )
    MiniTest.expect.equality(
        resolved.context[1].text,
        "function M.send(value)\n    return value\nend"
    )
end

T["context resolver"]["invalidates the symbol cache after a buffer change"] = function()
    local path = vim.fs.joinpath(root, "lua", "agent.lua")
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.bo[bufnr].filetype = "lua"

    local context = require("psst.context")
    local source = { bufnr = bufnr, path = path, filetype = "lua", line_count = 7 }
    MiniTest.expect.equality(context.symbols(source)[1].name, "M.send")
    vim.api.nvim_buf_set_lines(bufnr, 2, 5, false, { "function M.changed() end" })
    MiniTest.expect.equality(context.symbols(source)[1].name, "M.changed")
end

T["context resolver"]["whole files supersede ranges without removing diagnostics"] = function()
    local path = vim.fs.joinpath(root, "lua", "agent.lua")
    local range = {
        kind = "block",
        source = true,
        path = path,
        start_line = 2,
        end_line = 4,
        text = "range",
    }
    local diagnostic = {
        kind = "diagnostic",
        path = path,
        start_line = 3,
        end_line = 3,
        text = "diagnostic",
    }
    local whole = {
        kind = "file",
        source = true,
        path = vim.fs.joinpath(root, "lua", "..", "lua", "agent.lua"),
        whole_file = true,
        text = "whole",
    }

    local composed = require("psst.context").compose({ range, diagnostic, whole, whole })

    MiniTest.expect.equality(composed, { diagnostic, whole })
end

T["context resolver"]["exact ranges are deduplicated without merging overlaps"] = function()
    local path = vim.fs.joinpath(root, "lua", "agent.lua")
    local first = {
        kind = "block",
        source = true,
        path = path,
        start_line = 2,
        end_line = 4,
        text = "first",
    }
    local duplicate = vim.tbl_extend("force", {}, first, { text = "duplicate" })
    local overlap = vim.tbl_extend("force", {}, first, {
        start_line = 3,
        end_line = 5,
        text = "overlap",
    })

    local composed = require("psst.context").compose({ first, duplicate, overlap })

    MiniTest.expect.equality(composed, { first, overlap })
end

T["payload"] = MiniTest.new_set()

T["payload"]["renders Pi file blocks before the unchanged prompt"] = function()
    local rendered = require("psst.payload").render({
        context = {
            {
                kind = "file",
                source = true,
                path = '/tmp/a&"b.lua',
                symbol = 'M."send',
                start_line = 2,
                end_line = 4,
                text = "source",
            },
        },
        prompt = "  compare @a  ",
    })

    MiniTest.expect.equality(
        rendered,
        table.concat({
            '<file name="/tmp/a&amp;&quot;b.lua" symbol="M.&quot;send" lines="2-4">',
            "source",
            "</file>",
            "",
            "  compare @a  ",
        }, "\n")
    )
end

T["prompt integration"] = MiniTest.new_set()

local function invoke_mapping(buf, mode, lhs)
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(buf, mode)) do
        if mapping.lhs == lhs then
            mapping.callback()
            return
        end
    end
    error("Missing prompt mapping " .. lhs)
end

local function invoke_insert_mapping(buf, lhs) invoke_mapping(buf, "i", lhs) end

local function open_prompt(send)
    local path = vim.fs.joinpath(root, "lua", "agent.lua")
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    invocation_buf = vim.api.nvim_get_current_buf()
    vim.bo[invocation_buf].filetype = "lua"
    require("psst.prompt").open({
        cwd = root,
        invocation = {
            cwd = root,
            bufnr = invocation_buf,
            path = path,
            filetype = "lua",
            winid = vim.api.nvim_get_current_win(),
            cursor = { 1, 0 },
            selection = nil,
        },
        collect = {},
        send = send,
    })
    return vim.api.nvim_get_current_buf()
end

T["prompt integration"]["anchors actions in the window footer"] = function()
    local prompt_buf = open_prompt(function() return true end)
    local config = vim.api.nvim_win_get_config(0)
    local footer = {}
    for _, chunk in ipairs(config.footer) do
        footer[#footer + 1] = chunk[1]
    end

    MiniTest.expect.equality(table.concat(footer):find("[CR] read", 1, true) ~= nil, true)

    local namespace = vim.api.nvim_get_namespaces().psst_prompt_footer
    local marks = vim.api.nvim_buf_get_extmarks(prompt_buf, namespace, 0, -1, { details = true })
    MiniTest.expect.equality(marks[1][4].virt_lines, nil)

    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "close" })
    invoke_insert_mapping(prompt_buf, "<CR>")
end

T["prompt integration"]["retains a closed draft until successful submission"] = function()
    local prompt_buf = open_prompt(function() return true end)
    local draft = { "compare these", "then explain the difference" }
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, draft)
    vim.api.nvim_win_set_cursor(0, { 2, 10 })
    vim.cmd("stopinsert")
    local cursor = vim.api.nvim_win_get_cursor(0)
    cursor[2] = cursor[2] + 1

    invoke_mapping(prompt_buf, "n", "q")
    local reopened_buf = open_prompt(function() return true end)
    MiniTest.expect.equality(vim.api.nvim_buf_get_lines(reopened_buf, 0, -1, false), draft)
    MiniTest.expect.equality(vim.api.nvim_win_get_cursor(0), cursor)

    invoke_insert_mapping(reopened_buf, "<CR>")
    local empty_buf = open_prompt(function() return true end)
    MiniTest.expect.equality(vim.api.nvim_buf_get_lines(empty_buf, 0, -1, false), { "" })
    invoke_mapping(empty_buf, "n", "q")
end

T["prompt integration"]["refuses unresolved submission without closing the prompt"] = function()
    local sent = false
    local prompt_buf = open_prompt(function()
        sent = true
        return true
    end)
    local text = "read @missing.lua"
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { text })
    vim.api.nvim_win_set_cursor(0, { 1, #text })

    local notification
    local notify = vim.notify
    vim.notify = function(message) notification = message end
    invoke_insert_mapping(prompt_buf, "<CR>")
    vim.notify = notify

    MiniTest.expect.equality(sent, false)
    MiniTest.expect.equality(vim.api.nvim_buf_is_valid(prompt_buf), true)
    MiniTest.expect.equality(notification, "Cannot submit unresolved reference @missing.lua")
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "read @lua/agent.lua" })
    invoke_insert_mapping(prompt_buf, "<CR>")
end

T["prompt integration"]["submission re-resolves changed buffer contents"] = function()
    local request
    local prompt_buf = open_prompt(function(value)
        request = value
        return true
    end)
    local text = "read @lua/agent.lua:3-3"
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { text })
    vim.api.nvim_win_set_cursor(0, { 1, #text })
    vim.api.nvim_buf_set_lines(invocation_buf, 2, 3, false, { "function M.changed(value)" })

    invoke_insert_mapping(prompt_buf, "<CR>")

    MiniTest.expect.equality(request.context[1].text, "function M.changed(value)")
    MiniTest.expect.equality(request.prompt, text)
end

T["prompt integration"]["overview is concise, navigable, and returns to the prompt"] = function()
    local prompt_buf = open_prompt(function() return true end)
    local text = "read @missing.lua"
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { text })
    vim.api.nvim_win_set_cursor(0, { 1, #text })

    invoke_insert_mapping(prompt_buf, "<C-X>")
    MiniTest.expect.equality(vim.api.nvim_get_current_buf() ~= prompt_buf, true)
    MiniTest.expect.equality(vim.api.nvim_get_mode().mode, "n")
    local overview = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    MiniTest.expect.equality(overview[1], "Context overview")
    MiniTest.expect.equality(vim.tbl_contains(overview, "Unresolved references (1)"), true)
    MiniTest.expect.equality(table.concat(overview, "\n"):find("<file", 1, true), nil)

    vim.api.nvim_win_close(0, true)
    vim.wait(50)
    MiniTest.expect.equality(vim.api.nvim_get_current_buf(), prompt_buf)
    MiniTest.expect.equality(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), { text })
    vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "read @lua/agent.lua" })
    invoke_insert_mapping(prompt_buf, "<CR>")
end

return T
