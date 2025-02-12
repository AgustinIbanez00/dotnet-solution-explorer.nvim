local path_utils = {}
local Path = require("plenary.path")

function path_utils.normalize_path(path)
  local pat_normalized = tostring(Path:new(tostring(path:gsub("/", Path.path.sep))):absolute())
  return pat_normalized
end

return path_utils
