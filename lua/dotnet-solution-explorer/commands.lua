local cc = require("neo-tree.sources.common.commands")
local manager = require("neo-tree.sources.manager")

local vim = vim

local M = {}

M.refresh = function(state)
	manager.refresh("dotnet_solution", state)
end

M.show_debug_info = function(state)
	print(vim.inspect(state))
end

M.set_default_project = function(state)
        local tree = state.tree
        local node = tree:get_node()
        local id = node:get_id()
end

M.build_project = function(state)
        require("dotnet-solution-explorer").build_current_project()
end

M.run_project = function(state)
        require("dotnet-solution-explorer").run_current_project()
end

cc._add_common_commands(M)
return M
