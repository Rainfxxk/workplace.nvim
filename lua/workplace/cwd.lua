local config = require("workplace.config")
local registry = require("workplace.registry")
local util = require("workplace.util")

local M = {}

local function with_guard(fn, ...)
    local args = { ... }
    registry.guards.cwd = true
    local ok, result = pcall(fn, unpack(args))
    registry.guards.cwd = false
    if not ok then
        return false, result
    end
    return true, result
end

local function set_tcd(path)
    return vim.api.nvim_cmd({
        cmd = "tcd",
        args = { path },
    }, {})
end

function M.refresh_name(ws)
    if not ws or ws.name_custom then
        return
    end

    local name = registry.unique_name(util.basename(ws.cwd), ws.id)
    if name ~= ws.name then
        ws.name = name
        registry.write(ws)
        pcall(vim.cmd, "redrawtabline")
    end
end

function M.set_tab_cwd(tab, path)
    path = util.normalize_path(path)
    if not path then
        return false, "invalid path"
    end
    if not util.is_directory(path) then
        return false, "not a directory: " .. path
    end
    if not vim.api.nvim_tabpage_is_valid(tab) then
        return false, "invalid tab"
    end

    local current = vim.api.nvim_get_current_tabpage()
    if tab == current then
        local ok, err = with_guard(set_tcd, path)
        return ok, err
    end

    local ok_win, win = pcall(vim.api.nvim_tabpage_get_win, tab)
    if not ok_win or not vim.api.nvim_win_is_valid(win) then
        return false, "tab has no valid window"
    end

    local ok, err = with_guard(function()
        return vim.api.nvim_win_call(win, function()
            return set_tcd(path)
        end)
    end)
    return ok, err
end

function M.verify(ws)
    if not ws or not vim.api.nvim_tabpage_is_valid(ws.tab) then
        return false
    end

    local current_cwd = util.tab_cwd(ws.tab)
    if util.has_tab_cwd(ws.tab) and current_cwd == ws.cwd then
        return true
    end

    local ok, err = M.set_tab_cwd(ws.tab, ws.cwd)
    if not ok then
        util.notify("failed to set tab cwd to " .. tostring(ws.cwd) .. ": " .. tostring(err))
        return false
    end
    return true
end

function M.adopt(ws)
    if not ws or not vim.api.nvim_tabpage_is_valid(ws.tab) then
        return false
    end

    local actual = util.tab_cwd(ws.tab)
    local recorded = util.normalize_path(ws.cwd)
    local chosen = recorded

    if util.has_tab_cwd(ws.tab) and util.is_directory(actual) then
        chosen = actual
    elseif not util.is_directory(recorded) and util.is_directory(actual) then
        chosen = actual
    end

    if not chosen or not util.is_directory(chosen) then
        chosen = util.normalize_path(vim.fn.getcwd())
    end

    if not chosen or not util.is_directory(chosen) then
        util.notify("cannot determine a valid working directory for workspace " .. ws.name, vim.log.levels.ERROR)
        return false
    end

    ws.cwd = chosen
    local ok, err = M.set_tab_cwd(ws.tab, chosen)
    if not ok then
        util.notify("failed to lock workspace cwd: " .. tostring(err), vim.log.levels.ERROR)
        return false
    end

    M.refresh_name(ws)
    registry.write(ws)
    return true
end

function M.pin(ws)
    if not ws then
        return false
    end
    if not util.is_directory(ws.cwd) then
        local fallback = util.normalize_path(vim.fn.getcwd())
        if not fallback or not util.is_directory(fallback) then
            fallback = vim.fn.expand("~")
        end
        ws.cwd = fallback
    end
    return M.verify(ws)
end

function M.set(ws, path, opts)
    opts = opts or {}
    if not ws then
        return false
    end

    local normalized = util.normalize_path(path)
    if not normalized then
        util.notify("invalid working directory: " .. tostring(path), vim.log.levels.ERROR)
        return false
    end
    if not util.is_directory(normalized) then
        util.notify("not a directory: " .. normalized, vim.log.levels.ERROR)
        return false
    end

    local ok, err = M.set_tab_cwd(ws.tab, normalized)
    if not ok then
        util.notify("failed to set working directory: " .. tostring(err), vim.log.levels.ERROR)
        return false
    end

    ws.cwd = normalized
    M.refresh_name(ws)
    registry.write(ws)
    util.fire("Changed")

    if opts.notify ~= false then
        util.notify(string.format("cwd of %s -> %s", ws.name, normalized), vim.log.levels.INFO)
    end
    return true
end

function M.handle_dir_changed()
    if registry.guards.cwd or registry.guards.hydrating then
        return
    end

    local event = vim.v.event or {}
    if event.changed_window then
        return
    end

    local current_tab = vim.api.nvim_get_current_tabpage()
    local id = registry.by_tab[current_tab]
    local ws = id and registry.workspaces[id]
    if not ws then
        return
    end

    local cwd = util.normalize_path(event.cwd)
    if not cwd then
        return
    end

    if event.scope == "tabpage" then
        ws.cwd = cwd
        if not util.has_tab_cwd(ws.tab) then
            M.set_tab_cwd(ws.tab, ws.cwd)
        end
        M.refresh_name(ws)
        registry.write(ws)
        util.fire("Changed")
        return
    end

    if event.scope == "global" then
        if not config.options.cwd.sync_global_cd then
            return
        end
        ws.cwd = cwd
        local ok = M.set_tab_cwd(ws.tab, cwd)
        if not ok then
            util.notify("failed to re-lock tab cwd after :cd", vim.log.levels.WARN)
        end
        M.refresh_name(ws)
        registry.write(ws)
        util.fire("Changed")
    end
end

return M
