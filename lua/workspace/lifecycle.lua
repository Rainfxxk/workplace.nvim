local close = require("workspace.close")
local config = require("workspace.config")
local cwd = require("workspace.cwd")
local registry = require("workspace.registry")
local scope = require("workspace.scope")
local session = require("workspace.session")
local util = require("workspace.util")

local M = {}

local GROUP = "WorkspaceNvim"

local session_sequence = 0
local restored_sequence = -1

local function ensure_current_workspace()
    return registry.ensure(vim.api.nvim_get_current_tabpage())
end

local function sync_current()
    local ws = ensure_current_workspace()
    if not ws then
        return
    end
    registry.prune(ws)
    cwd.verify(ws)
    scope.collect_visible(ws)
    scope.sync(ws)
    return ws
end

function M.adopt_all()
    registry.clear_runtime()

    local tabs = vim.api.nvim_list_tabpages()
    for _, tab in ipairs(tabs) do
        local ws = registry.ensure(tab)
        if ws then
            cwd.adopt(ws)
            scope.collect_visible(ws)
        end
    end

    sync_current()
    pcall(vim.cmd, "redrawtabline")
end

function M.on_tab_new()
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end

    local tab = vim.api.nvim_get_current_tabpage()
    local ws = registry.ensure(tab)
    if not ws then
        return
    end

    local used_global_cwd = false
    if config.options.new_tab_cwd == "global" then
        local global_cwd = util.normalize_path(vim.fn.getcwd(-1, -1))
        if global_cwd and util.is_directory(global_cwd) then
            ws.cwd = global_cwd
            used_global_cwd = true
        end
    end

    if used_global_cwd then
        cwd.verify(ws)
        registry.write(ws)
    else
        cwd.adopt(ws)
    end

    -- Do not collect buffers here: TabNew can fire before :tabnew/nvim_open_tabpage
    -- has installed the final buffer, and the window may temporarily show the
    -- previous tab's buffer. Collection is deferred to TabEnter or TabNewEntered.
    ws._new_tab = true
    util.fire("Opened")
end

function M.on_tab_enter()
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end

    local ws = ensure_current_workspace()
    if not ws then
        return
    end

    registry.prune(ws)
    cwd.verify(ws)

    if ws._new_tab then
        -- New tabs can briefly display the inherited buffer during TabEnter.
        -- Synchronize the scope now, then collect again after the buffer switch
        -- has settled.
        ws._new_tab = nil
        scope.sync(ws)
        vim.schedule(function()
            if not vim.api.nvim_tabpage_is_valid(ws.tab)
                or registry.workspaces[ws.id] ~= ws
                or vim.api.nvim_get_current_tabpage() ~= ws.tab
            then
                return
            end
            scope.collect_visible(ws)
            scope.sync(ws)
        end)
    else
        scope.collect_visible(ws)
        scope.sync(ws)
    end

    util.fire("Entered")
end

function M.on_tab_new_entered()
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end

    local ws = ensure_current_workspace()
    if ws and vim.api.nvim_get_current_tabpage() == ws.tab then
        ws._new_tab = nil
        scope.collect_visible(ws)
        scope.sync(ws)
    end
end

function M.on_tab_closed_pre()
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end

    local tab = vim.api.nvim_get_current_tabpage()
    close.capture(tab)
end

function M.on_tab_closed()
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end

    local current_tab = vim.api.nvim_get_current_tabpage()
    local pending = {}

    for tab in pairs(registry.pending_close) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
            pending[#pending + 1] = registry.pending_close[tab]
        end
    end


    for _, capture in ipairs(pending) do
        local ws = registry.workspaces[capture.ws_id]
        if ws then
            registry.remove(ws)
        end
        registry.pending_close[capture.tab] = nil
        vim.schedule(function()
            close.finalize(capture)
        end)
    end

    for _, ws in ipairs(vim.tbl_values(vim.deepcopy(registry.workspaces))) do
        if not vim.api.nvim_tabpage_is_valid(ws.tab) then
            registry.remove(ws)
        end
    end

    local id = registry.by_tab[current_tab]
    if id and registry.workspaces[id] then
        scope.sync(registry.workspaces[id])
    end

    util.fire("Closed")
    pcall(vim.cmd, "redrawtabline")
end

function M.on_buf_enter(buf)
    if registry.guards.hydrating or registry.guards.quitting then
        return
    end
    scope.handle_buf_enter(buf)
end

function M.on_buf_delete(buf)
    scope.handle_buf_delete(buf)
end

function M.on_buf_wipeout(buf)
    scope.handle_buf_wipeout(buf)
end

function M.on_dir_changed()
    cwd.handle_dir_changed()
end

function M.on_session_load_pre()
    session_sequence = session_sequence + 1
    registry.guards.hydrating = true
    registry.pending_close = {}
    registry.close_plans = {}
end

function M.on_session_load_post()
    if restored_sequence == session_sequence then
        -- :source can emit SessionLoadPost more than once for one load.
        registry.guards.hydrating = false
        return
    end
    restored_sequence = session_sequence

    -- Allow the restored workspaces to be synchronized; destructive close
    -- handling was already suppressed by the SessionLoadPre guard.
    registry.guards.hydrating = false

    local restored = session.restore_current()
    if not restored then
        M.adopt_all()
    end

    util.fire("Restored")
end

function M.on_session_write_post()
    session.on_session_write()
end

function M.on_vim_leave_pre()
    registry.guards.quitting = true
    registry.pending_close = {}
    registry.close_plans = {}
end

function M.setup_autocmds()
    local group = vim.api.nvim_create_augroup(GROUP, { clear = true })

    vim.api.nvim_create_autocmd("TabNew", {
        group = group,
        callback = M.on_tab_new,
        desc = "workspace.nvim: register a new workspace",
    })
    vim.api.nvim_create_autocmd("TabEnter", {
        group = group,
        callback = M.on_tab_enter,
        desc = "workspace.nvim: activate the workspace",
    })
    vim.api.nvim_create_autocmd("TabNewEntered", {
        group = group,
        callback = M.on_tab_new_entered,
        desc = "workspace.nvim: synchronize a new workspace",
    })
    vim.api.nvim_create_autocmd("TabClosedPre", {
        group = group,
        callback = M.on_tab_closed_pre,
        desc = "workspace.nvim: capture workspace state before closing",
    })
    vim.api.nvim_create_autocmd("TabClosed", {
        group = group,
        callback = M.on_tab_closed,
        desc = "workspace.nvim: finalize a closed workspace",
    })
    vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
        group = group,
        callback = function(args)
            M.on_buf_enter(args.buf)
        end,
        desc = "workspace.nvim: attach a buffer to the current workspace",
    })
    vim.api.nvim_create_autocmd("BufDelete", {
        group = group,
        callback = function(args)
            M.on_buf_delete(args.buf)
        end,
        desc = "workspace.nvim: detach a deleted buffer",
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        group = group,
        callback = function(args)
            M.on_buf_wipeout(args.buf)
        end,
        desc = "workspace.nvim: detach a wiped buffer",
    })
    vim.api.nvim_create_autocmd("DirChanged", {
        group = group,
        callback = M.on_dir_changed,
        desc = "workspace.nvim: synchronize the workspace working directory",
    })
    vim.api.nvim_create_autocmd("SessionLoadPre", {
        group = group,
        callback = M.on_session_load_pre,
        desc = "workspace.nvim: suspend close cleanup while loading a session",
    })
    vim.api.nvim_create_autocmd("SessionLoadPost", {
        group = group,
        callback = M.on_session_load_post,
        desc = "workspace.nvim: rebuild workspace state after loading a session",
    })
    vim.api.nvim_create_autocmd("SessionWritePost", {
        group = group,
        callback = M.on_session_write_post,
        desc = "workspace.nvim: write workspace metadata next to the session",
    })
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = group,
        callback = M.on_vim_leave_pre,
        desc = "workspace.nvim: disable destructive cleanup while quitting",
    })
end

return M
