local registry = require("workspace.registry")
local util = require("workspace.util")

local M = {}

local subcommands = {
    "new",
    "open",
    "list",
    "close",
    "rename",
    "cwd",
    "next",
    "prev",
    "buffers",
}

local function starts_with(list, value)
    local matches = {}
    for _, item in ipairs(list) do
        if item:sub(1, #value) == value then
            matches[#matches + 1] = item
        end
    end
    return matches
end

local function complete(arglead, cmdline, cursorpos)
    local before = cmdline:sub(1, cursorpos - 1)
    local words = vim.split(before, "%s+", { trimempty = true })
    local ends_with_space = before:match("%s$") ~= nil

    if #words <= 1 or (#words == 2 and not ends_with_space) then
        return starts_with(subcommands, arglead)
    end

    local subcommand = words[2]
    local results = {}

    if subcommand == "open" or subcommand == "new" or subcommand == "cwd" then
        for _, dir in ipairs(vim.fn.getcompletion(arglead, "dir")) do
            results[#results + 1] = dir
        end
        if subcommand == "open" then
            for _, ws in ipairs(registry.list()) do
                if ws.name:sub(1, #arglead) == arglead then
                    results[#results + 1] = ws.name
                end
            end
        end
    end

    return results
end

local function usage()
    util.notify(
        "commands: :Workspace new [path] [name] | open [name|id|path] | list | close[!] | rename [name] | cwd [path] | next | prev | buffers",
        vim.log.levels.INFO
    )
end

local function workspace_lines()
    local lines = {}
    local current = registry.current()

    for _, ws in ipairs(registry.list()) do
        local marker = current and current.id == ws.id and "*" or " "
        local buffer_count = 0
        for _, buf in ipairs(ws.buffers) do
            if vim.api.nvim_buf_is_valid(buf) then
                buffer_count = buffer_count + 1
            end
        end
        lines[#lines + 1] = string.format(
            "%s %d:%s  %s  (%d buffers)",
            marker,
            util.tab_number(ws.tab) or 0,
            ws.name,
            ws.cwd,
            buffer_count
        )
    end

    if #lines == 0 then
        lines[1] = "no workspaces"
    end
    util.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

local function buffer_lines()
    local api = require("workspace.api")
    local lines = {}
    for _, buf in ipairs(api.buffers()) do
        lines[#lines + 1] = string.format(
            "%d%s %s",
            buf,
            vim.bo[buf].modified and " [+]" or "",
            vim.fn.fnamemodify(vim.api.nvim_buf_get_name(buf), ":~:.")
        )
    end
    if #lines == 0 then
        lines[1] = "no buffers in this workspace"
    end
    util.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

local function argument_text(args)
    return vim.trim(table.concat(vim.list_slice(args.fargs, 2), " "))
end

local function new_workspace(args)
    local api = require("workspace.api")
    local parts = vim.list_slice(args.fargs, 2)
    local raw = vim.trim(table.concat(parts, " "))
    if raw == "" then
        api.new()
        return
    end

    local first = parts[1]
    local first_path = util.normalize_path(first)

    if first_path and util.is_directory(first_path) then
        local name_parts = vim.list_slice(parts, 2)
        local name = #name_parts > 0 and table.concat(name_parts, " ") or nil
        api.new({ cwd = first_path, name = name })
        return
    end

    if first:find("[/\\]") or first:sub(1, 1) == "~" then
        util.notify("not a directory: " .. first, vim.log.levels.ERROR)
        return
    end

    api.new({ name = raw })
end

function M.dispatch(args)
    local api = require("workspace.api")
    local subcommand = args.fargs[1]

    if not subcommand then
        usage()
        return
    end

    if subcommand == "new" then
        new_workspace(args)
    elseif subcommand == "open" then
        local raw = argument_text(args)
        if raw == "" then
            api.open(nil)
        else
            api.open(raw)
        end
    elseif subcommand == "list" then
        workspace_lines()
    elseif subcommand == "close" then
        api.close(nil, { force = args.bang })
    elseif subcommand == "rename" then
        local raw = argument_text(args)
        if raw == "" then
            local ws = registry.current()
            vim.ui.input({ prompt = "Workspace name: ", default = ws and ws.name or "" }, function(input)
                if input and vim.trim(input) ~= "" then
                    api.rename(nil, input)
                end
            end)
        else
            api.rename(nil, raw)
        end
    elseif subcommand == "cwd" then
        local raw = argument_text(args)
        if raw == "" then
            local ws = registry.current()
            util.notify(
                string.format(
                    "workspace cwd: %s\neffective cwd: %s",
                    ws and ws.cwd or "?",
                    vim.fn.getcwd()
                ),
                vim.log.levels.INFO
            )
        else
            api.set_cwd(nil, raw)
        end
    elseif subcommand == "next" then
        if #vim.api.nvim_list_tabpages() > 1 then
            vim.cmd("tabnext")
        end
    elseif subcommand == "prev" then
        if #vim.api.nvim_list_tabpages() > 1 then
            vim.cmd("tabprevious")
        end
    elseif subcommand == "buffers" then
        buffer_lines()
    else
        util.notify("unknown subcommand: " .. subcommand, vim.log.levels.ERROR)
        usage()
    end
end

function M.register()
    vim.api.nvim_create_user_command("Workspace", M.dispatch, {
        nargs = "*",
        bang = true,
        complete = complete,
        desc = "Manage workspace.nvim workspaces",
        force = true,
    })

    vim.api.nvim_create_user_command("WorkspaceClose", function(args)
        require("workspace.api").close(nil, { force = args.bang })
    end, {
        nargs = 0,
        bang = true,
        desc = "Close the current workspace",
        force = true,
    })
end

return M
