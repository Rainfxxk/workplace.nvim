local config = require("workplace.config")
local cwd = require("workplace.cwd")
local registry = require("workplace.registry")
local scope = require("workplace.scope")
local util = require("workplace.util")

local M = {}

M.VERSION = 1
M.SIDECAR_SUFFIX = ".workplace.json"

local function session_path(path)
    path = path or vim.v.this_session
    if type(path) ~= "string" or path == "" then
        return nil
    end

    return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

function M.sidecar_path(path)
    local session = session_path(path)
    if not session then
        return nil
    end
    return session .. M.SIDECAR_SUFFIX
end

local function persistable_buffer_path(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return nil
    end

    local buftype = vim.bo[buf].buftype
    if buftype == "nofile"
        or buftype == "prompt"
        or buftype == "quickfix"
        or buftype == "terminal"
        or buftype == "help"
    then
        return nil
    end

    local name = vim.api.nvim_buf_get_name(buf)
    if name == "" or name:match("^%a[%w+.-]*://") then
        return nil
    end

    return util.normalize_path(name)
end

local function active_buffer_path(ws)
    if not vim.api.nvim_tabpage_is_valid(ws.tab) then
        return nil
    end

    local ok, win = pcall(vim.api.nvim_tabpage_get_win, ws.tab)
    if not ok or not vim.api.nvim_win_is_valid(win) then
        return nil
    end

    return persistable_buffer_path(vim.api.nvim_win_get_buf(win))
end

function M.snapshot()
    local snapshot = {
        version = M.VERSION,
        saved_at = os.time(),
        active_index = nil,
        workspaces = {},
    }

    local current_tab = vim.api.nvim_get_current_tabpage()
    for index, tab in ipairs(vim.api.nvim_list_tabpages()) do
        if tab == current_tab then
            snapshot.active_index = index
            break
        end
    end

    for _, ws in ipairs(registry.list()) do
        local buffers = {}
        local seen = {}

        for _, buf in ipairs(ws.buffers) do
            local path = persistable_buffer_path(buf)
            if path and not seen[path] then
                seen[path] = true
                buffers[#buffers + 1] = path
            end
        end

        local active = active_buffer_path(ws)
        snapshot.workspaces[#snapshot.workspaces + 1] = {
            id = ws.id,
            name = ws.name,
            name_custom = ws.name_custom == true,
            cwd = util.normalize_path(ws.cwd),
            active_buffer = active,
            anchor = active,
            buffers = buffers,
        }
    end

    return snapshot
end

function M.serialize()
    return M.snapshot()
end

function M.save(path)
    local sidecar = M.sidecar_path(path)
    if not sidecar then
        return false, "no session path"
    end

    local snapshot = M.snapshot()
    snapshot.session = session_path(path)

    local ok, encoded = pcall(vim.json.encode, snapshot)
    if not ok or type(encoded) ~= "string" then
        util.notify("failed to encode workspace session state: " .. tostring(encoded), vim.log.levels.ERROR)
        return false, encoded
    end

    local directory = vim.fs.dirname(sidecar)
    if directory and directory ~= "" then
        vim.fn.mkdir(directory, "p")
    end

    local temporary = sidecar .. ".tmp"
    local written = vim.fn.writefile({ encoded }, temporary)
    if written ~= 0 then
        util.notify("failed to write workspace sidecar: " .. temporary, vim.log.levels.ERROR)
        return false, "write failed"
    end

    local renamed, rename_err = vim.uv.fs_rename(temporary, sidecar)
    if not renamed then
        pcall(vim.fn.delete, temporary)
        util.notify("failed to finalize workspace sidecar: " .. tostring(rename_err), vim.log.levels.ERROR)
        return false, rename_err
    end

    return true
end

function M.read(path)
    local sidecar = M.sidecar_path(path)
    if not sidecar or vim.fn.filereadable(sidecar) ~= 1 then
        return nil
    end

    local ok, lines = pcall(vim.fn.readfile, sidecar)
    if not ok or type(lines) ~= "table" then
        return nil
    end

    local decoded_ok, snapshot = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not decoded_ok or type(snapshot) ~= "table" then
        return nil
    end
    if snapshot.version ~= M.VERSION or type(snapshot.workspaces) ~= "table" then
        return nil
    end

    return snapshot
end

local function normalized_path(value)
    if type(value) ~= "string" or value == "" then
        return nil
    end
    return util.normalize_path(value)
end

local function buffer_from_saved_path(path)
    path = normalized_path(path)
    if not path then
        return nil
    end

    local existing = vim.fn.bufnr(path)
    if existing > 0 and vim.api.nvim_buf_is_valid(existing) then
        return existing
    end

    if vim.fn.filereadable(path) ~= 1 then
        return nil
    end

    local created = vim.fn.bufadd(path)
    if created > 0 and vim.api.nvim_buf_is_valid(created) then
        return created
    end
    return nil
end

local function current_buffer_path(tab)
    local ok, win = pcall(vim.api.nvim_tabpage_get_win, tab)
    if not ok or not vim.api.nvim_win_is_valid(win) then
        return nil
    end
    return persistable_buffer_path(vim.api.nvim_win_get_buf(win))
end

function M.restore(snapshot)
    if type(snapshot) ~= "table"
        or snapshot.version ~= M.VERSION
        or type(snapshot.workspaces) ~= "table"
    then
        return false
    end

    local tabs = vim.api.nvim_list_tabpages()
    if #tabs == 0 then
        return false
    end

    local entries = {}
    for _, entry in ipairs(snapshot.workspaces) do
        if type(entry) == "table" then
            entries[#entries + 1] = entry
        end
    end
    if #entries == 0 then
        return false
    end

    local ok, err = pcall(function()
        registry.clear_runtime()

        local used = {}
        local matched = {}

        local function take_entry(entry_index)
            used[entry_index] = true
            return entries[entry_index]
        end

        local function match_entry(tab, index)
            local record = util.get_tab_var(tab, registry.VAR)
            if type(record) == "table" and type(record.id) == "string" then
                for entry_index, entry in ipairs(entries) do
                    if not used[entry_index] and entry.id == record.id then
                        return take_entry(entry_index)
                    end
                end
            end

            if entries[index] and not used[index] then
                return take_entry(index)
            end

            local active = current_buffer_path(tab)
            if active then
                for entry_index, entry in ipairs(entries) do
                    if not used[entry_index] then
                        local anchor = normalized_path(entry.anchor or entry.active_buffer)
                        if anchor == active then
                            return take_entry(entry_index)
                        end
                    end
                end
            end

            local actual_cwd = util.tab_cwd(tab)
            if actual_cwd then
                for entry_index, entry in ipairs(entries) do
                    if not used[entry_index] then
                        local entry_cwd = normalized_path(entry.cwd)
                        if entry_cwd == actual_cwd then
                            return take_entry(entry_index)
                        end
                    end
                end
            end

            for entry_index in ipairs(entries) do
                if not used[entry_index] then
                    return take_entry(entry_index)
                end
            end

            return nil
        end

        for index, tab in ipairs(tabs) do
            local entry = match_entry(tab, index)
            local ws

            if entry then
                local name = type(entry.name) == "string" and entry.name or nil
                ws = registry.create({
                    tab = tab,
                    id = type(entry.id) == "string" and entry.id or nil,
                    name = name,
                    name_custom = entry.name_custom == true,
                })
            else
                ws = registry.create({ tab = tab })
            end

            local desired_cwd = entry and normalized_path(entry.cwd) or nil
            if desired_cwd and util.is_directory(desired_cwd) then
                ws.cwd = desired_cwd
                cwd.verify(ws)
            else
                cwd.adopt(ws)
            end
            registry.write(ws)

            if entry and type(entry.buffers) == "table" then
                for _, saved_path in ipairs(entry.buffers) do
                    local buf = buffer_from_saved_path(saved_path)
                    if buf then
                        registry.attach(ws, buf)
                    end
                end
            end

            scope.collect_visible(ws)
            matched[#matched + 1] = { ws = ws, entry = entry }
        end

        local current_tab = vim.api.nvim_get_current_tabpage()

        for _, pair in ipairs(matched) do
            local ws = pair.ws
            local entry = pair.entry
            if entry then
                local path = normalized_path(entry.active_buffer)
                if path then
                    local buf = vim.fn.bufnr(path)
                    if buf > 0 and vim.api.nvim_buf_is_valid(buf) then
                        for _, win in ipairs(util.tab_windows(ws.tab)) do
                            if vim.api.nvim_win_get_buf(win) == buf then
                                if ws.tab == current_tab then
                                    pcall(vim.api.nvim_set_current_win, win)
                                else
                                    pcall(vim.api.nvim_tabpage_set_win, ws.tab, win)
                                end
                                break
                            end
                        end
                    end
                end
            end
        end

        local active_id = registry.by_tab[current_tab]
        if active_id and registry.workspaces[active_id] then
            local ws = registry.workspaces[active_id]
            scope.collect_visible(ws)
            scope.sync(ws)
        end

        pcall(vim.cmd, "redrawtabline")
    end)

    if not ok then
        util.notify("failed to restore workspace session: " .. tostring(err), vim.log.levels.ERROR)
        return false
    end
    return true
end

function M.on_session_write()
    if not config.options.session.enabled then
        return
    end

    local path = session_path()
    if not path then
        return
    end
    M.save(path)
end

function M.restore_current()
    if not config.options.session.enabled then
        return false
    end

    local snapshot = M.read()
    if not snapshot then
        return false
    end

    return M.restore(snapshot)
end

function M.load(path)
    local snapshot = M.read(path)
    if not snapshot then
        return false
    end
    return M.restore(snapshot)
end

return M
