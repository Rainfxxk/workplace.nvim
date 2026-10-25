local M = {}

function M.normalize_path(path)
    if type(path) ~= "string" or path == "" then
        return nil
    end

    local expanded = vim.fn.expand(path)
    local absolute = vim.fn.fnamemodify(expanded, ":p")
    local normalized = vim.fs.normalize(absolute)

    if #normalized > 1 and normalized:sub(-1) == "/" then
        normalized = normalized:sub(1, -2)
    end

    return normalized
end

function M.is_directory(path)
    return type(path) == "string" and vim.fn.isdirectory(path) == 1
end

function M.basename(path)
    local normalized = M.normalize_path(path)
    if not normalized then
        return "workspace"
    end

    local name = vim.fs.basename(normalized)
    if not name or name == "" then
        name = "workspace"
    end
    return name
end

function M.path_equal(left, right)
    local a = M.normalize_path(left)
    local b = M.normalize_path(right)
    return a ~= nil and b ~= nil and a == b
end

function M.tab_number(tab)
    local ok, number = pcall(vim.api.nvim_tabpage_get_number, tab)
    return ok and number or nil
end

function M.tab_cwd(tab)
    local number = M.tab_number(tab)
    if not number then
        return M.normalize_path(vim.fn.getcwd())
    end

    local ok, cwd = pcall(vim.fn.getcwd, -1, number)
    if ok and type(cwd) == "string" and cwd ~= "" then
        return M.normalize_path(cwd)
    end
    return M.normalize_path(vim.fn.getcwd())
end

function M.has_tab_cwd(tab)
    local number = M.tab_number(tab)
    if not number then
        return false
    end
    local ok, result = pcall(vim.fn.haslocaldir, -1, number)
    return ok and result == 1
end

function M.is_floating(win)
    if not vim.api.nvim_win_is_valid(win) then
        return false
    end
    local ok, config = pcall(vim.api.nvim_win_get_config, win)
    return ok and config.relative ~= ""
end

function M.tab_windows(tab)
    local ok, windows = pcall(vim.api.nvim_tabpage_list_wins, tab)
    return ok and windows or {}
end

--- Buffers currently shown in non-floating windows of a tab.
--- @param tab integer
--- @return integer[]
function M.visible_buffers(tab)
    local result = {}
    local seen = {}

    for _, win in ipairs(M.tab_windows(tab)) do
        if not M.is_floating(win) then
            local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
            if ok and vim.api.nvim_buf_is_valid(buf) and not seen[buf] then
                seen[buf] = true
                result[#result + 1] = buf
            end
        end
    end

    return result
end

function M.buf_in_nonfloat_window(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end

    local ok, windows = pcall(vim.fn.win_findbuf, buf)
    if not ok or not windows then
        return false
    end

    for _, win in ipairs(windows) do
        if not M.is_floating(win) then
            return true
        end
    end

    return false
end

function M.buf_displayed(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    local ok, windows = pcall(vim.fn.win_findbuf, buf)
    return ok and windows ~= nil and #windows > 0
end

function M.escape_tabline(text)
    return (tostring(text):gsub("%%", "%%%%"):gsub("\n", " "))
end

function M.notify(message, level)
    local ok, config = pcall(require, "workspace.config")
    local configured = vim.log.levels.WARN
    if ok then
        configured = config.options.notify
    end
    if configured == false then
        return
    end

    vim.notify("workspace.nvim: " .. tostring(message), level or configured)
end

function M.fire(name)
    pcall(vim.api.nvim_exec_autocmds, "User", {
        pattern = "WorkspaceNvim" .. name,
    })
end

function M.get_tab_var(tab, name)
    local ok, value = pcall(vim.api.nvim_tabpage_get_var, tab, name)
    return ok and value or nil
end

function M.set_tab_var(tab, name, value)
    return pcall(vim.api.nvim_tabpage_set_var, tab, name, value)
end

function M.del_tab_var(tab, name)
    return pcall(vim.api.nvim_tabpage_del_var, tab, name)
end

return M
