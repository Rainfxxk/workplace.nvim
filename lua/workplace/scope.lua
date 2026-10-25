local config = require("workplace.config")
local registry = require("workplace.registry")
local util = require("workplace.util")

local M = {}

function M.eligible(buf, win)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    if win and util.is_floating(win) then
        return false
    end

    local buftype = vim.bo[buf].buftype
    if config.is_excluded_buftype(buftype) then
        return false
    end
    if config.is_excluded_filetype(vim.bo[buf].filetype) then
        return false
    end

    return true
end

function M.set_listed(buf, listed)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end
    pcall(function()
        vim.bo[buf].buflisted = listed
    end)
end

function M.collect_visible(ws)
    if not ws or not vim.api.nvim_tabpage_is_valid(ws.tab) then
        return 0
    end

    local added = 0
    for _, win in ipairs(util.tab_windows(ws.tab)) do
        if not util.is_floating(win) then
            local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
            if ok and M.eligible(buf, win) then
                if registry.attach(ws, buf) then
                    added = added + 1
                end
            end
        end
    end

    return added
end

function M.sync(ws)
    if not ws or not vim.api.nvim_tabpage_is_valid(ws.tab) then
        return
    end
    if not config.options.buffer_scope.enabled then
        return
    end
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end

    registry.prune(ws)

    local current_members = {}
    for _, buf in ipairs(ws.buffers) do
        current_members[buf] = true
    end

    local managed = registry.managed_buffers()
    local previous_guard = registry.guards.scope
    registry.guards.scope = true

    local ok, err = pcall(function()
        for buf in pairs(current_members) do
            if vim.api.nvim_buf_is_valid(buf) and not vim.bo[buf].buflisted then
                M.set_listed(buf, true)
            end
        end

        for buf in pairs(managed) do
            if not current_members[buf] and vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].buflisted then
                M.set_listed(buf, false)
            end
        end
    end)

    registry.guards.scope = previous_guard

    if not ok then
        util.notify("failed to synchronize buffer scope: " .. tostring(err), vim.log.levels.ERROR)
    end

    pcall(vim.cmd, "redrawtabline")
end

function M.handle_buf_enter(buf)
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local win = vim.api.nvim_get_current_win()
    if not M.eligible(buf, win) then
        return
    end

    local ws = registry.current()
    if not ws then
        return
    end

    if registry.attach(ws, buf) then
        local was_guarded = registry.guards.scope
        registry.guards.scope = true
        M.set_listed(buf, true)
        registry.guards.scope = was_guarded
    elseif not vim.bo[buf].buflisted then
        local was_guarded = registry.guards.scope
        registry.guards.scope = true
        M.set_listed(buf, true)
        registry.guards.scope = was_guarded
    end
end

function M.handle_buf_delete(buf)
    if registry.guards.scope or registry.guards.hydrating or registry.guards.quitting then
        return
    end
    registry.detach_everywhere(buf)
    registry.orphans[buf] = nil
end

function M.handle_buf_wipeout(buf)
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end
    registry.detach_everywhere(buf)
    registry.orphans[buf] = nil
end

return M
