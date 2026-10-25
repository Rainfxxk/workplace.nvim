local config = require("workspace.config")
local registry = require("workspace.registry")
local util = require("workspace.util")

local M = {}

local RENDERER = "%!v:lua.require'workspace.tabline'.render()"

local function is_modified(ws)
    for _, buf in ipairs(ws.buffers) do
        if vim.api.nvim_buf_is_valid(buf) and vim.bo[buf].modified then
            return true
        end
    end
    return false
end

local function workspace_name(tab, number)
    local id = registry.by_tab[tab]
    local ws = id and registry.workspaces[id] or nil
    if ws then
        return ws.name
    end

    local stored = util.get_tab_var(tab, "name")
    if type(stored) == "string" and stored ~= "" then
        return stored
    end

    return "Tab " .. number
end

function M.render()
    local parts = {}
    local current = vim.api.nvim_get_current_tabpage()
    local tabs = vim.api.nvim_list_tabpages()

    for _, tab in ipairs(tabs) do
        local number = util.tab_number(tab) or 1
        local id = registry.by_tab[tab]
        local ws = id and registry.workspaces[id] or nil
        local name = workspace_name(tab, number)

        local label = name
        if config.options.tabline.show_index then
            label = string.format("%d:%s", number, label)
        end
        if config.options.tabline.show_modified and ws and is_modified(ws) then
            label = label .. " +"
        end

        local highlight = tab == current and "%#TabLineSel#" or "%#TabLine#"
        parts[#parts + 1] = highlight .. "%" .. number .. "T " .. util.escape_tabline(label) .. " "
    end

    local rendered = table.concat(parts)
    if #tabs > 1 then
        rendered = rendered .. "%#TabLineFill#%T%=%#TabLine#%999Xclose"
    else
        rendered = rendered .. "%#TabLineFill#%T"
    end

    return rendered
end

function M.install()
    local enabled = config.options.tabline.enabled
    if enabled == false then
        return
    end

    if enabled == "auto" then
        local current = vim.o.tabline
        if current ~= "" and not current:find("workspace.tabline", 1, true) then
            return
        end
    end

    vim.o.tabline = RENDERER
end

function M.redraw()
    pcall(vim.cmd, "redrawtabline")
end

return M
