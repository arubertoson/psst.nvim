vim.cmd("packadd blink.cmp")

local MiniTest = _G.MiniTest or require("mini.test")
if not _G.MiniTest then MiniTest.setup({ silent = true }) end

local root

local T = MiniTest.new_set({
    hooks = {
        pre_case = function()
            root = vim.fn.tempname()
            vim.fs.mkdir(vim.fs.joinpath(root, "src", "deep"), { parents = true })
            vim.fs.mkdir(vim.fs.joinpath(root, ".hidden"), { parents = true })
            vim.fn.writefile({
                "local function child()",
                "    return true",
                "end",
            }, vim.fs.joinpath(root, "src", "child.lua"))
            vim.fn.writefile({ "content" }, vim.fs.joinpath(root, "src", "deep", "list.zig"))
            vim.fn.writefile({ "content" }, vim.fs.joinpath(root, ".hidden", "secret.zig"))
        end,
        post_case = function()
            vim.cmd("silent! %bwipeout!")
            vim.fn.delete(root, "rf")
        end,
    },
})

local function complete_files(line)
    local response
    local source = require("psst.completion.files").new({
        get_cwd = function() return root end,
    })
    source:get_completions({
        line = line,
        cursor = { 1, #line },
        bounds = { start_col = 2, length = #line - 1 },
    }, function(result) response = result end)

    MiniTest.expect.equality(vim.wait(1000, function() return response ~= nil end), true)
    return response
end

T["project file source"] = MiniTest.new_set()

T["project file source"]["fuzzy matches files at any depth"] = function()
    local response = complete_files("@list.zig")

    MiniTest.expect.equality(response.items[1].label, "src/deep/list.zig")
    MiniTest.expect.equality(response.items[1].textEdit, {
        newText = "src/deep/list.zig",
        range = {
            start = { line = 0, character = 1 },
            ["end"] = { line = 0, character = 9 },
        },
    })
end

T["project file source"]["includes hidden files"] = function()
    local response = complete_files("@secret.zig")

    MiniTest.expect.equality(response.items[1].label, ".hidden/secret.zig")
end

T["project file source"]["only completes inline references"] = function()
    local response = complete_files("list.zig")

    MiniTest.expect.equality(response.items, {})
end

T["project file source"]["adds inline reference trigger characters"] = function()
    local source = require("psst.completion.files").new({ get_cwd = function() return root end })
    local triggers = source:get_trigger_characters()

    MiniTest.expect.equality(vim.tbl_contains(triggers, "@"), true)
    MiniTest.expect.equality(vim.tbl_contains(triggers, "#"), true)
end

T["symbol source"] = MiniTest.new_set()

local function complete_symbols(line)
    local path = vim.fs.joinpath(root, "src", "child.lua")
    local invocation_buf = vim.fn.bufadd(path)
    vim.fn.bufload(invocation_buf)
    vim.bo[invocation_buf].filetype = "lua"
    local source = require("psst.completion.symbol").new({
        get_cwd = function() return root end,
        get_invocation_buf = function() return invocation_buf end,
    })
    local response
    source:get_completions({
        line = line,
        cursor = { 1, #line },
    }, function(result) response = result end)
    return response
end

T["symbol source"]["lists symbols immediately after an explicit file hash"] = function()
    local response = complete_symbols("@src/child.lua#")

    MiniTest.expect.equality(response.items[1].label, "child")
    MiniTest.expect.equality(response.items[1].textEdit.range, {
        start = { line = 0, character = 15 },
        ["end"] = { line = 0, character = 15 },
    })
end

T["symbol source"]["lists invocation-buffer symbols after a current-file hash"] = function()
    local response = complete_symbols("@#")

    MiniTest.expect.equality(response.items[1].label, "child")
end

T["symbol source"]["filters symbols using the selector text"] = function()
    local response = complete_symbols("@src/child.lua#chi")

    MiniTest.expect.equality(response.items[1].label, "child")
    MiniTest.expect.equality(response.items[1].textEdit, {
        newText = "child",
        range = {
            start = { line = 0, character = 15 },
            ["end"] = { line = 0, character = 18 },
        },
    })
end

return T
