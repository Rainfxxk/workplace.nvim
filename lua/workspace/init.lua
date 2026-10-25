local api = require("workspace.api")
local commands = require("workspace.commands")
local config = require("workspace.config")
local lifecycle = require("workspace.lifecycle")
local session = require("workspace.session")
local tabline = require("workspace.tabline")
local util = require("workspace.util")

local M = {}

local function load_telescope_extension()
    if not config.options.telescope.load_extension then
        return
    end

    -- telescope.nvim is optional: only load the extension when it is
    -- installed and reachable on the runtimepath.
    local telescope_ok, telescope = pcall(require, "telescope")
    if not telescope_ok then
        return
    end

    local extension_ok, extension_err = pcall(telescope.load_extension, "workspace")
    if not extension_ok then
        util.notify(
            "failed to load the Telescope extension: " .. tostring(extension_err),
            vim.log.levels.WARN
        )
    end
end

function M.setup(opts)
    if vim.fn.has("nvim-0.12") ~= 1 then
        error("workspace.nvim requires Neovim >= 0.12")
    end

    config.setup(opts)
    lifecycle.setup_autocmds()
    commands.register()

    local scope_loaded = pcall(vim.api.nvim_get_autocmds, { group = "ScopeAU" })
    if scope_loaded or package.loaded["scope"] ~= nil then
        util.notify(
            "scope.nvim is loaded and manages the same buflisted state; disable it before using workspace.nvim",
            vim.log.levels.ERROR
        )
    end

    lifecycle.adopt_all()

    -- If a session was sourced before this plugin finished loading (for example
    -- with a very lazy setup), SessionLoadPost has already fired. Apply the
    -- sidecar now so restart-through-session still restores workspace metadata.
    if vim.v.this_session ~= nil and vim.v.this_session ~= "" then
        if not session.restore_current() then
            lifecycle.adopt_all()
        end
    end

    tabline.install()

    vim.g.loaded_workspace_nvim = 1
    load_telescope_extension()
    util.fire("Setup")
    return M
end

M.current = api.current
M.list = api.list
M.find = api.find
M.new = api.new
M.open = api.open
M.switch = api.switch
M.close = api.close
M.rename = api.rename
M.set_cwd = api.set_cwd
M.cwd = api.cwd
M.buffers = api.buffers
M.attach_buffer = api.attach_buffer
M.detach_buffer = api.detach_buffer
M.refresh = api.refresh

M.session = require("workspace.session")

return M
