vim.opt.rtp:append(vim.fn.getcwd())

local telescope_ok = pcall(require, "telescope")
if not telescope_ok then
    io.stdout:write("telescope tests skipped (telescope.nvim not on runtimepath)\n")
    vim.cmd("qa!")
    return
end

local failures = {}

local function ok(condition, message)
    if not condition then
        failures[#failures + 1] = message
        io.stdout:write("FAIL: " .. message .. "\n")
    end
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/a", "p")
vim.fn.mkdir(tmp .. "/b", "p")

local workplace = require("workplace")
ok(package.loaded["telescope._extensions.workplace"] == nil, "workplace extension is not loaded before setup")

workplace.setup({
    tabline = { enabled = false },
    notify = false,
})
ok(
    package.loaded["telescope._extensions.workplace"] ~= nil,
    "workplace.setup() auto-loads the Telescope extension"
)

workplace.new({ cwd = vim.fs.normalize(tmp .. "/a"), name = "TelescopeA" })
workplace.new({ cwd = vim.fs.normalize(tmp .. "/b"), name = "TelescopeB" })

local telescope = require("telescope")
telescope.setup({})
local extension = telescope.load_extension("workplace")
ok(type(extension.workplace) == "function", "workplace extension exports the picker")
ok(type(extension.workspaces) == "function", "workplace extension exports the plural alias")

extension.workplace({})

local function find_prompt()
    local state = require("telescope.actions.state")
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        local picker = state.get_current_picker(buf)
        if picker then
            return buf, picker
        end
    end
    return nil, nil
end

local found = vim.wait(3000, function()
    local buf = find_prompt()
    return buf ~= nil
end, 50)
ok(found, "Telescope picker opens")

local prompt, picker = find_prompt()
if prompt and picker then
    vim.wait(2000, function()
        local selection = picker:get_selection()
        return selection ~= nil and selection.value ~= nil
    end, 50)

    picker:set_selection(1)
    local selection = picker:get_selection()
    local selected_name = selection and selection.value and selection.value.name or nil
    ok(selected_name ~= nil, "Telescope picker has a selected workspace")

    require("telescope.actions").select_default(prompt)
    vim.wait(1000, function()
        return selected_name ~= nil and workplace.current().name == selected_name
    end, 50)

    ok(
        selected_name ~= nil and workplace.current().name == selected_name,
        ":Telescope workplace switches to the selected workspace"
    )
else
    ok(false, "Telescope picker is ready for selection")
end

vim.o.hidden = true
if #failures > 0 then
    io.stdout:write(string.format("%d telescope test(s) failed\n", #failures))
    vim.cmd("cquit 1")
else
    io.stdout:write("telescope tests passed\n")
    vim.cmd("qa!")
end
