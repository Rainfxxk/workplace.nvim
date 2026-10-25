# workplace.nvim

Treat every Neovim tab as a workspace with its own working directory, buffer list, and window layout. Names and state persist with your session.

> Requires Neovim >= 0.12.

## Features

- **One tab, one workspace** — every tab, including `:tabnew`, `:tab split`, and `<C-w>T`, is a workspace.
- **Independent working directory** — each workspace has its own tab-local cwd via `:tcd`. `:cd` updates the current workspace only, and switching tabs restores the right directory.
- **Independent buffer list** — bufferline, Telescope buffers, `:ls`, and `:bnext` show only the current workspace's buffers. Buffers stay loaded, so undo history and LSP state are preserved.
- **Native window layouts** — each tab keeps its own windows; no layout is reimplemented.
- **Names and tabline** — workspaces are named after their directory and can be renamed. An optional built-in tabline is included.
- **Session persistence** — workspace names, cwd, and buffers are restored when you reload a session saved with `:mksession` (works with persistence.nvim and auto-session).
- **Safe closing** — shared buffers are never deleted; exclusive unmodified buffers are cleaned up; modified buffers prompt or are preserved.
- **Telescope picker** — switch workspaces with `:Telescope workplace`.
- **No default keymaps, no required dependencies.**

## Requirements

- Neovim >= 0.12.
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for the workspace picker.
- **scope.nvim must be disabled** — both plugins manage `buflisted` and conflict. `:checkhealth workplace` reports it.

## Installation

With lazy.nvim:

```lua
{
    "your-username/workplace.nvim",
    lazy = false, -- setup() should run early for session restore
    config = function()
        require("workplace").setup()
    end,
}
```

Or install manually and call setup:

```lua
require("workplace").setup()
```

`setup()` is required; the plugin does not load itself.

## Usage

| Command | Description |
| --- | --- |
| `:Workplace new [path] [name]` | Create a workspace, optionally with a directory and name. |
| `:Workplace open [name\|id\|path]` | Switch to a workspace; with no argument, pick from a list. |
| `:Workplace list` | List all workspaces. |
| `:Workplace rename [name]` | Rename the current workspace. |
| `:Workplace cwd [path]` | Show or set the current workspace's directory. |
| `:Workplace close[!]` | Close the current workspace; `!` discards unsaved exclusive buffers. |
| `:WorkplaceClose[!]` | Short alias for `:Workplace close`. |
| `:Workplace next` / `prev` | Go to the next / previous workspace. |
| `:Workplace buffers` | List the current workspace's buffers. |

Example session:

```vim
" Create a workspace in a project directory
:Workplace new ~/code/myproject
" Open some files, then create another workspace
:Workplace new ~/code/other-project
" Switch back and forth; each tab keeps its own files and cwd
:Workplace open
:tabnext
```

Optional keymaps:

```lua
vim.keymap.set("n", "<leader>wn", "<cmd>Workplace new<cr>")
vim.keymap.set("n", "<leader>wo", "<cmd>Workplace open<cr>")
vim.keymap.set("n", "<leader>wl", "<cmd>Workplace list<cr>")
vim.keymap.set("n", "<leader>wc", "<cmd>WorkplaceClose<cr>")
```

## Configuration

Defaults are usually enough:

```lua
require("workplace").setup()
```

Options you may want to change:

| Option | Default | Description |
| --- | --- | --- |
| `new_tab_cwd` | `"inherit"` | cwd for native new tabs; `"inherit"` or `"global"`. |
| `tabline.enabled` | `"auto"` | Built-in tabline; set `false` if you use bufferline's tabs mode or tabby. |
| `close.modified` | `"prompt"` | Ask before closing with modified buffers, or `"keep"` them. |
| `close.delete_unmodified` | `true` | Delete exclusive unmodified buffers when closing. |
| `session.enabled` | `true` | Save and restore workspace state with sessions. |
| `telescope.load_extension` | `true` | Load the Telescope extension from `setup()`. |
| `notify` | `vim.log.levels.WARN` | Notification level; `false` disables notifications. |


Recommended Neovim options (already the defaults in 0.12):

```lua
vim.o.hidden = true
vim.o.autochdir = false
vim.o.sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,terminal"
```

## Telescope

If Telescope is installed, the extension is loaded automatically:

```vim
:Telescope workplace
```

If Telescope is lazy-loaded, call `require("telescope").load_extension("workplace")` after it loads.

## Sessions

Workspace state is written to `<session>.workplace.json` when you save a session with `:mksession`, and restored when the session is loaded. This works out of the box with persistence.nvim and auto-session.

Terminal contents, unnamed buffers, and unsaved changes are not restored; only file buffers are.

## Good to Know

- All tabs become workspaces, including `:tab help` and `:tab split`.
- Workspaces are logically isolated, not process-isolated: registers, quickfix, LSP clients, and other global state are shared.
- The same file opened in two workspaces is the same buffer, sharing undo and LSP state.
- `:lcd` / `:bcd` keep their native behavior and are not folded into the workspace cwd.
