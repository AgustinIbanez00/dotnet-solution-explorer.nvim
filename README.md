# dotnet-solution-explorer.nvim

A Neo-tree source that brings a Visual Studio style Solution Explorer to Neovim. It parses `.sln` files and MSBuild projects so you can browse, build and run .NET solutions without leaving the editor.

## Features

- Displays the full solution tree including projects and folders
- Shows the target framework next to each project
- Build, run or create new files directly from the tree
- Supports .NET Framework on Windows and SDK style projects on any platform

## Requirements

- [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)
- [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
- [xml2lua](https://github.com/manoelcampos/xml2lua) (install via `luarocks install xml2lua`)
- The `dotnet` CLI for .NET Core/NET projects
- Visual Studio Build Tools when compiling .NET Framework projects on Windows

## Installation

### Using lazy.nvim

```lua
{
  "your-user/dotnet-solution-explorer.nvim",
  dependencies = { "nvim-neo-tree/neo-tree.nvim", "nvim-lua/plenary.nvim" },
  config = function()
    require("dotnet-solution-explorer").setup({
      follow_current_file = { enabled = true },
    })
  end,
}
```

Add `"dotnet_solution"` to the `sources` list of Neo-tree:

```lua
require("neo-tree").setup({
  sources = { "filesystem", "buffers", "git_status", "document_symbols", "dotnet_solution" },
})
```

### Using packer.nvim

```lua
use {
  "your-user/dotnet-solution-explorer.nvim",
  requires = { "nvim-neo-tree/neo-tree.nvim", "nvim-lua/plenary.nvim" },
  config = function()
    require("dotnet-solution-explorer").setup({})
  end,
}
```

## Commands

- `:DotNetBuild` – compile the project under the cursor
- `:DotNetRun` – run the selected project using `dotnet run` or the built executable
- `:DotNetAddFile` – create a new file inside the current folder and update the project

You can map these inside the Neo-tree window. For example:

```lua
require("neo-tree").setup({
  sources = { "filesystem", "buffers", "git_status", "document_symbols", "dotnet_solution" },
  window = {
    mappings = {
      ["B"] = "build_project",
      ["R"] = "run_project",
      ["a"] = "add_file",
    },
  },
})
```

## Contributing

1. Fork the repository and create a new branch for your changes.
2. Make your edits and ensure all Lua files parse correctly:
   ```bash
   luac -p $(find lua -name '*.lua')
   ```
3. Submit a pull request describing your changes.

Bug reports, feature requests and contributions are very welcome!

## License

MIT
