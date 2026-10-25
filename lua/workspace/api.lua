local close = require("workspace.close")
local cwd = require("workspace.cwd")
local lifecycle = require("workspace.lifecycle")
local registry = require("workspace.registry")
local scope = require("workspace.scope")
local util = require("workspace.util")

local M = {}

local function normalize_workspace(ws)
    if ws == nil then
        return registry.current()
    end
    return registry.get(ws)
end

local function switch_to_tab(tab)
    if not vim.api.nvim_tabpage_is_valid(tab) then
        return false
    end
    local ok = pcall(vim.api.nvim_set_current_tabpage, tab)
    if ok then
        pcall(vim.cmd, "redrawtabline")
    end
    return ok
end

function M.current()
    return registry.current()
end

function M.list()
    return registry.list()
end

function M.find(identifier)
    return registry.get(identifier)
end

function M.new(opts)
    opts = opts or {}

    local desired_cwd = opts.cwd
    if desired_cwd ~= nil then
        desired_cwd = util.normalize_path(desired_cwd)
        if not desired_cwd then
            util.notify("invalid working directory: " .. tostring(opts.cwd), vim.log.levels.ERROR)
            return nil
        end
        if not util.is_directory(desired_cwd) then
            util.notify("not a directory: " .. desired_cwd, vim.log.levels.ERROR)
            return nil
        end
    end

    local base_ws = registry.current()
    local inherited_cwd = desired_cwd or (base_ws and base_ws.cwd) or util.normalize_path(vim.fn.getcwd())

    local buffer = vim.api.nvim_create_buf(true, false)
    local enter = opts.enter ~= false

    local ok, tab = pcall(vim.api.nvim_open_tabpage, buffer, enter, {})
    if not ok then
        if not enter then
            util.notify("Neovim 0.12+ is required to create a tab without entering it", vim.log.levels.ERROR)
            return nil
        end
        pcall(vim.cmd, "tabnew")
        tab = vim.api.nvim_get_current_tabpage()
    end

    if not tab or not vim.api.nvim_tabpage_is_valid(tab) then
        util.notify("failed to create workspace", vim.log.levels.ERROR)
        return nil
    end

    local ws = registry.ensure(tab)
    if not ws then
        return nil
    end

    if inherited_cwd and util.is_directory(inherited_cwd) then
        ws.cwd = inherited_cwd
        cwd.verify(ws)
        cwd.refresh_name(ws)
        registry.write(ws)
    else
        cwd.adopt(ws)
    end

    if opts.name and tostring(opts.name) ~= "" then
        ws.name = registry.unique_name(tostring(opts.name), ws.id)
        ws.name_custom = true
        registry.write(ws)
    end

    ws._new_tab = nil
    scope.collect_visible(ws)
    if enter then
        scope.sync(ws)
    else
        local active = registry.current()
        if active and active.id ~= ws.id then
            scope.sync(active)
        end
    end

    pcall(vim.cmd, "redrawtabline")
    return ws
end

function M.open(identifier)
    if identifier == nil then
        local items = registry.list()
        if #items == 0 then
            util.notify("no workspaces", vim.log.levels.WARN)
            return nil
        end

        vim.ui.select(items, {
            prompt = "Select a workspace:",
            format_item = function(ws)
                return string.format("%s  %s", ws.name, ws.cwd)
            end,
        }, function(choice)
            if choice then
                M.switch(choice)
            end
        end)
        return nil
    end

    local ws = registry.get(identifier)
    if ws then
        M.switch(ws)
        return ws
    end

    local path = util.normalize_path(tostring(identifier))
    if path and util.is_directory(path) then
        ws = registry.get(path)
        if ws then
            M.switch(ws)
            return ws
        end
        return M.new({ cwd = path })
    end

    util.notify("workspace not found: " .. tostring(identifier), vim.log.levels.ERROR)
    return nil
end

function M.switch(ws)
    ws = normalize_workspace(ws)
    if not ws then
        util.notify("workspace not found", vim.log.levels.ERROR)
        return false
    end
    return switch_to_tab(ws.tab)
end

function M.close(ws, opts)
    ws = normalize_workspace(ws)
    if not ws then
        util.notify("workspace not found", vim.log.levels.ERROR)
        return
    end
    close.request(ws, opts)
end

function M.rename(ws, name)
    ws = normalize_workspace(ws)
    if not ws then
        util.notify("workspace not found", vim.log.levels.ERROR)
        return false
    end
    if type(name) ~= "string" or vim.trim(name) == "" then
        util.notify("workspace name cannot be empty", vim.log.levels.ERROR)
        return false
    end

    ws.name = registry.unique_name(vim.trim(name), ws.id)
    ws.name_custom = true
    registry.write(ws)
    pcall(vim.cmd, "redrawtabline")
    util.fire("Changed")
    return true
end

function M.set_cwd(ws, path)
    ws = normalize_workspace(ws)
    if not ws then
        util.notify("workspace not found", vim.log.levels.ERROR)
        return false
    end
    return cwd.set(ws, path)
end

function M.cwd(ws)
    ws = normalize_workspace(ws)
    return ws and ws.cwd or nil
end

function M.buffers(ws)
    ws = normalize_workspace(ws)
    if not ws then
        return {}
    end

    local result = {}
    for _, buf in ipairs(ws.buffers) do
        if vim.api.nvim_buf_is_valid(buf) then
            result[#result + 1] = buf
        end
    end
    return result
end

function M.attach_buffer(buf, ws)
    ws = normalize_workspace(ws)
    if not ws or not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    local added = registry.attach(ws, buf)
    local active = registry.current()
    if added and active and active.id == ws.id then
        scope.sync(ws)
    end
    return added
end

function M.detach_buffer(buf, ws)
    ws = normalize_workspace(ws)
    if not ws then
        return false
    end
    local removed = registry.detach(ws, buf)
    local active = registry.current()
    if active and active.id == ws.id then
        scope.sync(ws)
    end
    return removed
end

function M.refresh()
    lifecycle.adopt_all()
    return M.list()
end

return M
