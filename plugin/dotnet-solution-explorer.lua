local ok_manager, manager = pcall(require, "neo-tree.sources.manager")
if not ok_manager then
  return
end

local ok_neotree, neotree = pcall(require, "neo-tree")
if not ok_neotree then
  return
end

local src = require("dotnet-solution-explorer")
local config = neotree.ensure_config()
config.sources = config.sources or {}
local found = false
for _, s in ipairs(config.sources) do
  if s == src.name then
    found = true
    break
  end
end
if not found then
  table.insert(config.sources, src.name)
end
manager.setup(src.name, config[src.name] or {}, config, src)
