# dotnet-solution-explorer.nvim
Support to Solution Explorer for NeoVim

## Build current project

When the cursor is on a project node you can compile it using the command:

```
:DotNetBuild
```

It is also possible to map a key inside the Neo-tree window. Example:

```lua
require("neo-tree").setup({
    sources = { "filesystem", "buffers", "git_status", "document_symbols", "dotnet_solution" },
    window = {
        mappings = {
            ["B"] = "build_project",
        },
    },
})
```
