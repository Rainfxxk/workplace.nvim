local util = require("workspace.util")

local M = {}

M.VAR = "workspace_nvim"

M.workspaces = {}
M.by_tab = {}
M.memberships = {}
M.orphans = {}
M.pending_close = {}
M.close_plans = {}

M.guards = {
    scope = false,
    cwd = false,
    hydrating = false,
    quitting = false,
}

local id_counter = 0

function M.new_id()
    id_counter = id_counter + 1
    return string.format("wp-%.0f-%d", vim.uv.hrtime(), id_counter)
end

function M.clear_runtime()
    for key in pairs(M.workspaces) do
        M.workspaces[key] = nil
    end
    for key in pairs(M.by_tab) do
        M.by_tab[key] = nil
    end
    for key in pairs(M.memberships) do
        M.memberships[key] = nil
    end
    for key in pairs(M.orphans) do
        M.orphans[key] = nil
    end
    for key in pairs(M.pending_close) do
        M.pending_close[key] = nil
    end
    for key in pairs(M.close_plans) do
        M.close_plans[key] = nil
    end
    M.guards.scope = false
    M.guards.cwd = false
    M.guards.hydrating = false
    M.guards.quitting = false
end

function M.write(ws)
    if not ws or not vim.api.nvim_tabpage_is_valid(ws.tab) then
        return
    end

    local buffers = {}
    for i, buf in ipairs(ws.buffers) do
        buffers[i] = buf
    end

    util.set_tab_var(ws.tab, M.VAR, {
        id = ws.id,
        name = ws.name,
        name_custom = ws.name_custom,
        cwd = ws.cwd,
        buffers = buffers,
    })
    util.set_tab_var(ws.tab, "name", ws.name)
end

function M.unique_name(base, exclude_id)
    base = tostring(base or "workspace"):gsub("%s+", " ")
    base = vim.trim(base)
    if base == "" then
        base = "workspace"
    end

    local used = {}
    for id, ws in pairs(M.workspaces) do
        if id ~= exclude_id then
            used[ws.name] = true
        end
    end

    if not used[base] then
        return base
    end

    local index = 2
    while used[string.format("%s (%d)", base, index)] do
        index = index + 1
    end
    return string.format("%s (%d)", base, index)
end

function M.register(ws)
    M.workspaces[ws.id] = ws
    M.by_tab[ws.tab] = ws.id

    for _, buf in ipairs(ws.buffers) do
        M.memberships[buf] = M.memberships[buf] or {}
        M.memberships[buf][ws.id] = true
        M.orphans[buf] = nil
    end
end

--- @param opts {tab?: integer, id?: string, name?: string, cwd?: string, name_custom?: boolean}
function M.create(opts)
    opts = opts or {}
    local tab = opts.tab or vim.api.nvim_get_current_tabpage()

    if M.by_tab[tab] then
        return M.workspaces[M.by_tab[tab]]
    end

    local cwd = util.normalize_path(opts.cwd) or util.tab_cwd(tab)
    if not cwd then
        cwd = util.normalize_path(vim.fn.getcwd())
    end

    local id = opts.id
    if not id or type(id) ~= "string" or M.workspaces[id] then
        id = M.new_id()
        while M.workspaces[id] do
            id = M.new_id()
        end
    end

    local name = opts.name
    if name == nil or name == "" then
        name = M.unique_name(util.basename(cwd))
    else
        name = M.unique_name(name)
    end

    local ws = {
        id = id,
        tab = tab,
        name = name,
        name_custom = opts.name_custom == true
            or (opts.name ~= nil and opts.name_custom == nil),
        cwd = cwd,
        buffers = {},
        _set = {},
    }

    M.register(ws)
    M.write(ws)
    return ws
end

function M.load_tab(tab)
    local record = util.get_tab_var(tab, M.VAR)
    if type(record) ~= "table" then
        return nil
    end

    local cwd = util.normalize_path(record.cwd)
    if not cwd or not util.is_directory(cwd) then
        cwd = util.tab_cwd(tab)
    end

    local id = type(record.id) == "string" and record.id or nil
    if not id or M.workspaces[id] then
        id = M.new_id()
    end

    local name = type(record.name) == "string" and record.name or nil
    if not name or name == "" then
        name = M.unique_name(util.basename(cwd))
    end

    local ws = {
        id = id,
        tab = tab,
        name = name,
        name_custom = record.name_custom == true,
        cwd = cwd,
        buffers = {},
        _set = {},
    }

    if type(record.buffers) == "table" then
        for _, buf in ipairs(record.buffers) do
            if type(buf) == "number"
                and vim.api.nvim_buf_is_valid(buf)
                and not ws._set[buf]
            then
                ws._set[buf] = true
                ws.buffers[#ws.buffers + 1] = buf
            end
        end
    end

    M.register(ws)
    M.write(ws)
    return ws
end

function M.ensure(tab)
    tab = tab or vim.api.nvim_get_current_tabpage()

    local id = M.by_tab[tab]
    if id and M.workspaces[id] then
        return M.workspaces[id]
    end

    return M.load_tab(tab) or M.create({ tab = tab })
end

function M.current()
    return M.ensure(vim.api.nvim_get_current_tabpage())
end

function M.get(identifier)
    if identifier == nil then
        return M.current()
    end

    if type(identifier) == "table" and identifier.id then
        return M.workspaces[identifier.id]
    end

    if type(identifier) == "number" then
        local id = M.by_tab[identifier]
        return id and M.workspaces[id] or nil
    end

    if type(identifier) == "string" then
        if M.workspaces[identifier] then
            return M.workspaces[identifier]
        end

        for _, ws in pairs(M.workspaces) do
            if ws.name == identifier then
                return ws
            end
        end

        local normalized = util.normalize_path(identifier)
        if normalized then
            for _, ws in pairs(M.workspaces) do
                if ws.cwd == normalized then
                    return ws
                end
            end
        end
    end

    return nil
end

function M.list()
    local list = {}
    for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
        local id = M.by_tab[tab]
        if id and M.workspaces[id] then
            list[#list + 1] = M.workspaces[id]
        end
    end
    return list
end

function M.attach(ws, buf)
    if not ws or not vim.api.nvim_buf_is_valid(buf) then
        return false
    end
    if ws._set[buf] then
        return false
    end

    ws._set[buf] = true
    ws.buffers[#ws.buffers + 1] = buf
    M.memberships[buf] = M.memberships[buf] or {}
    M.memberships[buf][ws.id] = true
    M.orphans[buf] = nil
    M.write(ws)
    return true
end

function M.detach(ws, buf)
    if not ws or not ws._set[buf] then
        return false
    end

    ws._set[buf] = nil
    for i, value in ipairs(ws.buffers) do
        if value == buf then
            table.remove(ws.buffers, i)
            break
        end
    end

    local membership = M.memberships[buf]
    if membership then
        membership[ws.id] = nil
        if next(membership) == nil then
            M.memberships[buf] = nil
        end
    end

    M.write(ws)
    return true
end

function M.detach_everywhere(buf)
    local membership = M.memberships[buf]
    if not membership then
        return {}
    end

    local ids = vim.tbl_keys(membership)
    for _, id in ipairs(ids) do
        local ws = M.workspaces[id]
        if ws then
            M.detach(ws, buf)
        end
    end
    M.memberships[buf] = nil
    return ids
end

function M.is_exclusive(buf, ws_id)
    local membership = M.memberships[buf]
    if not membership then
        return true
    end

    for id in pairs(membership) do
        if id ~= ws_id and M.workspaces[id] then
            return false
        end
    end
    return true
end

function M.exclusive_buffers(ws)
    local list = {}
    for _, buf in ipairs(ws.buffers) do
        if M.is_exclusive(buf, ws.id) then
            list[#list + 1] = buf
        end
    end
    return list
end

function M.shared_buffers(ws)
    local list = {}
    for _, buf in ipairs(ws.buffers) do
        if not M.is_exclusive(buf, ws.id) then
            list[#list + 1] = buf
        end
    end
    return list
end

function M.managed_buffers()
    local result = {}
    for buf in pairs(M.memberships) do
        result[buf] = true
    end
    return result
end

function M.prune(ws)
    if not ws then
        return
    end
    for i = #ws.buffers, 1, -1 do
        local buf = ws.buffers[i]
        if not vim.api.nvim_buf_is_valid(buf) then
            ws._set[buf] = nil
            table.remove(ws.buffers, i)
            local membership = M.memberships[buf]
            if membership then
                membership[ws.id] = nil
                if next(membership) == nil then
                    M.memberships[buf] = nil
                end
            end
        end
    end
    M.write(ws)
end

function M.remove(ws, opts)
    if not ws then
        return
    end
    opts = opts or {}

    for _, buf in ipairs(ws.buffers) do
        local membership = M.memberships[buf]
        if membership then
            membership[ws.id] = nil
            if next(membership) == nil then
                M.memberships[buf] = nil
            end
        end
    end

    M.workspaces[ws.id] = nil
    M.by_tab[ws.tab] = nil

    if opts.clear_vars and vim.api.nvim_tabpage_is_valid(ws.tab) then
        util.del_tab_var(ws.tab, M.VAR)
        util.del_tab_var(ws.tab, "name")
    end
end

function M.remember_orphan(buf)
    if vim.api.nvim_buf_is_valid(buf) then
        M.orphans[buf] = true
    end
end

return M
