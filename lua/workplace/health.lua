local config = require("workplace.config")
local registry = require("workplace.registry")
local session = require("workplace.session")
local util = require("workplace.util")

local M = {}

local function has_scope_conflict()
    local ok = pcall(vim.api.nvim_get_autocmds, { group = "ScopeAU" })
    return ok or package.loaded["scope"] ~= nil
end

function M.check()
    vim.health.start("workplace.nvim")

    if vim.fn.has("nvim-0.12") == 1 then
        vim.health.ok("Neovim >= 0.12")
    else
        vim.health.error("workplace.nvim requires Neovim >= 0.12")
    end

    if has_scope_conflict() then
        vim.health.error("scope.nvim is loaded; it conflicts with workplace.nvim. Disable scope.nvim.")
    else
        vim.health.ok("no scope.nvim conflict detected")
    end

    if vim.o.autochdir then
        vim.health.warn("'autochdir' is enabled; it conflicts with per-workspace cwd")
    else
        vim.health.ok("'autochdir' is disabled")
    end

    if vim.o.hidden then
        vim.health.ok("'hidden' is enabled")
    else
        vim.health.warn("'hidden' is disabled; hidden buffers may lose undo state when unloaded")
    end

    local sessionoptions = vim.o.sessionoptions
    for _, option in ipairs({ "tabpages", "curdir", "buffers" }) do
        if sessionoptions:find(option, 1, true) then
            vim.health.ok("sessionoptions contains " .. option)
        else
            vim.health.warn("sessionoptions does not contain " .. option)
        end
    end

    local tabs = vim.api.nvim_list_tabpages()
    local workspaces = registry.list()

    if #tabs ~= #workspaces then
        vim.health.warn(
            string.format("registry has %d workspace(s) for %d tab(s); try workplace.refresh()", #workspaces, #tabs)
        )
    else
        vim.health.ok("registry matches the current tabs")
    end

    for _, ws in ipairs(workspaces) do
        local label = string.format("%s (%s)", ws.name, ws.cwd)
        if not vim.api.nvim_tabpage_is_valid(ws.tab) then
            vim.health.error(label .. ": tab is no longer valid")
        elseif not util.has_tab_cwd(ws.tab) then
            vim.health.warn(label .. ": tab has no explicit tcd")
        elseif not util.is_directory(ws.cwd) then
            vim.health.error(label .. ": cwd does not exist")
        else
            vim.health.ok(label)
        end

        local tabnr = util.tab_number(ws.tab)
        if tabnr then
            local effective = vim.fn.getcwd()
            local tab_cwd = vim.fn.getcwd(-1, tabnr)
            if tabnr == vim.fn.tabpagenr() and effective ~= tab_cwd then
                vim.health.info(
                    "effective cwd differs from tab cwd in the current tab (lcd/bcd is active): "
                        .. effective
                )
            end
        end
    end

    local tabline = vim.o.tabline
    if tabline ~= "" and not tabline:find("workplace.tabline", 1, true) then
        vim.health.info("a custom 'tabline' is set; workplace.nvim did not install its renderer")
    end

    if not config.options.session.enabled then
        vim.health.info("session sidecar persistence is disabled")
    else
        local session_file = vim.v.this_session
        if session_file == nil or session_file == "" then
            vim.health.info(
                "no active session file; workspace state will be saved next to a session written by :mksession"
            )
        else
            local sidecar = session.sidecar_path(session_file)
            if sidecar and vim.fn.filereadable(sidecar) == 1 then
                if session.read(session_file) then
                    vim.health.ok("workspace sidecar is readable: " .. sidecar)
                else
                    vim.health.error("workspace sidecar is not valid JSON: " .. sidecar)
                end
            else
                vim.health.info(
                    "no workspace sidecar for the current session yet; it will be written on the next save"
                )
            end
        end
    end

    if package.loaded["persistence"] ~= nil then
        vim.health.info("persistence.nvim detected; its mksession saves will include the workspace sidecar")
    end
end

return M
