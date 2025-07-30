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

## Run current project

When a .NET project is selected you can execute it with:

```
:DotNetRun
```

Example key mapping inside Neo-tree:

```lua
require("neo-tree").setup({
    sources = { "filesystem", "buffers", "git_status", "document_symbols", "dotnet_solution" },
    window = {
        mappings = {
            ["R"] = "run_project",
        },
    },
})
```
