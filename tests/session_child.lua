local workplace = require("workplace")

local result = {
    workspaces = {},
    listed = {},
    tabs = vim.fn.tabpagenr("$"),
    current = nil,
}

local current = workplace.current()
if current then
    result.current = current.name
end

for _, ws in ipairs(workplace.list()) do
    local files = {}
    for _, buf in ipairs(workplace.buffers(ws)) do
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" then
            files[#files + 1] = vim.fs.normalize(name)
        end
    end

    local active = ""
    local ok, win = pcall(vim.api.nvim_tabpage_get_win, ws.tab)
    if ok and vim.api.nvim_win_is_valid(win) then
        local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
        if name ~= "" then
            active = vim.fs.normalize(name)
        end
    end

    result.workspaces[#result.workspaces + 1] = {
        name = ws.name,
        cwd = vim.fs.normalize(ws.cwd),
        active = active,
        files = files,
    }
end

for _, info in ipairs(vim.fn.getbufinfo({ buflisted = 1 })) do
    if info.name ~= "" then
        result.listed[#result.listed + 1] = vim.fs.normalize(info.name)
    end
end

io.stdout:write("\nWORKPLACE_RESULT:" .. vim.json.encode(result) .. "\n")
io.stdout:flush()
vim.cmd("qa!")
