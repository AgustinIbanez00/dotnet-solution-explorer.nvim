local vim = vim
local Path = require("plenary.path")

local path = {}

function path.basename(filepath)
  local filename = filepath:match("([^/\\]+)$") or ""
  return filename
end

path.sep = "/"

local M = {}

local vbProjectGuid = "{F184B08F-C81C-45F6-A57F-5ABD9991F28F}"
local csProjectGuid = "{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}"
local cpsProjectGuid = "{13B669BE-BB05-4DDF-9536-439F39A36129}"
local cpsCsProjectGuid = "{9A19103F-16F7-4668-BE54-9A1E7A4F7556}"
local cpsVbProjectGuid = "{778DAE3C-4631-46EA-AA77-85C1314464D9}"
local vjProjectGuid = "{E6FDF86B-F3D1-11D4-8576-0002A516ECE8}"
local vcProjectGuid = "{8BC9CEB8-8B4A-11D0-8D11-00A0C91BC942}"
local fsProjectGuid = "{F2A71F9B-5D33-465A-A702-920D77279786}"
local cpsFsProjectGuid = "{6EC3EE1D-3C4E-46DD-8F32-0CC8E7565705}"
local dbProjectGuid = "{C8D11400-126E-41CD-887F-60BD40844F9E}"
local wdProjectGuid = "{2CFEAB61-6A3B-4EB8-B523-560B4BEEF521}"
local webProjectGuid = "{E24C65DC-7377-472B-9ABA-BC803B73C61A}"
local solutionFolderGuid = "{2150E333-8FDC-42A3-9474-1A3956D46DE8}"

local ProjectInSolution = {}
ProjectInSolution.__index = ProjectInSolution

function ProjectInSolution:new(solution)
  local o = {
    solution = solution,
    projectTypeId = nil,
    projectName = "",
    relativePath = "",
    fullPath = "",
    projectGuid = "",
    projectType = "",
    parentProjectGuid = nil,
    dependencies = {},
    webProperties = {},
    files = {},
    configurations = {},
  }
  setmetatable(o, self)
  return o
end

function ProjectInSolution:addFile(name, filepath)
  table.insert(self.files, { name = name, path = filepath })
end

function ProjectInSolution:addDependency(guid)
  table.insert(self.dependencies, guid)
end

function ProjectInSolution:addWebProperty(name, value)
  self.webProperties[name] = value
end

function ProjectInSolution:setProjectConfiguration(configName, projConfig)
  self.configurations[configName] = projConfig
end

local SolutionConfigurationInSolution = {}
SolutionConfigurationInSolution.__index = SolutionConfigurationInSolution

function SolutionConfigurationInSolution:new(configuration, platform)
  local o = {
    configuration = configuration,
    platform = platform,
    fullName = configuration .. "|" .. platform,
  }
  setmetatable(o, self)
  return o
end

local ProjectConfigurationInSolution = {}
ProjectConfigurationInSolution.__index = ProjectConfigurationInSolution

function ProjectConfigurationInSolution:new(configuration, platform, shouldBuild)
  local o = {
    configuration = configuration or "",
    platform = platform or "",
    build = shouldBuild or false,
  }
  setmetatable(o, self)
  return o
end

local SolutionProjectType = {
  unknown = "unknown",
  knownToBeMSBuildFormat = "knownToBeMSBuildFormat",
  solutionFolder = "solutionFolder",
  webProject = "webProject",
  webDeploymentProject = "webDeploymentProject",
}

local SolutionFile = {}
SolutionFile.__index = SolutionFile

-- Constructor "privado"
function SolutionFile:_new()
  local o = {
    _lines = {},
    _currentLineIndex = -1,
    _projects = {},
    _solutionConfigurations = {},
    _currentVisualStudioVersion = "",
    _name = "",
    _fullPath = "",
    _folderPath = "",
    _version = "",
    _solutionContainsWebProjects = false,
    _solutionContainsWebDeploymentProjects = false,
  }
  setmetatable(o, self)
  return o
end

function SolutionFile:name()
  return self._name
end
function SolutionFile:fullPath()
  return self._fullPath
end
function SolutionFile:folderPath()
  return self._folderPath
end
function SolutionFile:version()
  return self._version
end
function SolutionFile:currentVisualStudioVersion()
  return self._currentVisualStudioVersion
end
function SolutionFile:containsWebProjects()
  return self._solutionContainsWebProjects
end
function SolutionFile:containsWebDeploymentProjects()
  return self._solutionContainsWebDeploymentProjects
end
function SolutionFile:projectsById()
  return self._projects
end

function SolutionFile:projects()
  local result = {}
  for _, proj in pairs(self._projects) do
    table.insert(result, proj)
  end
  return result
end

function SolutionFile:configurations()
  return self._solutionConfigurations
end

function SolutionFile.parse(solutionFullPath)
  local solution = SolutionFile:_new()

  solution._fullPath = solutionFullPath
  solution._folderPath = vim.fn.fnamemodify(solutionFullPath, ":h")
  solution._name = vim.fn.fnamemodify(solutionFullPath, ":t:r")

  local contentTable = vim.fn.readfile(solutionFullPath)
  solution._lines = contentTable
  solution._currentLineIndex = 1

  solution:_parseSolution()
  return solution
end

function SolutionFile:_readLine()
  if self._currentLineIndex > #self._lines then
    return nil
  end
  local line = self._lines[self._currentLineIndex]
  self._currentLineIndex = self._currentLineIndex + 1

  if line then
    line = line:gsub("^%s*(.-)%s*$", "%1")
  end
  return line
end

function SolutionFile:_parseSolution()
  self:_parseFileHeader()

  local str = nil
  local rawProjectConfigurationsEntries = nil

  while true do
    str = self:_readLine()
    if not str then
      break
    end

    if str:match("^Project%(") then
      self:_parseProject(str)
    elseif str:match("^GlobalSection%(NestedProjects%)") then
      self:_parseNestedProjects()
    elseif str:match("^GlobalSection%(SolutionConfigurationPlatforms%)") then
      self:_parseSolutionConfigurations()
    elseif str:match("^GlobalSection%(ProjectConfigurationPlatforms%)") then
      rawProjectConfigurationsEntries = self:_parseProjectConfigurations()
    elseif str:match("^VisualStudioVersion") then
      self._currentVisualStudioVersion = self:_parseVisualStudioVersion(str)
    else
      -- ignoramos
    end
  end

  if rawProjectConfigurationsEntries then
    self:_processProjectConfigurationSection(rawProjectConfigurationsEntries)
  end
end

function SolutionFile:_parseFileHeader()
  local slnFileHeaderNoVersion = "Microsoft Visual Studio Solution File, Format Version "

  for _ = 1, 2 do
    local str = self:_readLine()
    if not str then
      break
    end

    if str:match("^" .. slnFileHeaderNoVersion) then
      self._version = str:sub(#slnFileHeaderNoVersion + 1)
      return
    end
  end
end

function SolutionFile:_parseProject(firstLine)
  local proj = ProjectInSolution:new(self)

  self:_parseFirstProjectLine(firstLine, proj)

  while true do
    local line = self:_readLine()
    if not line then
      break
    end

    if line == "EndProject" then
      break
    elseif line:match("^ProjectSection%(SolutionItems%)") then
      line = self:_readLine()
      while line and not line:match("^EndProjectSection") do
        local m = { line:match("^(.*)%=(.*)$") }
        if #m >= 2 then
          local fileName = path.basename((m[1] or ""):gsub("\\", path.sep):gsub("^%s*(.-)%s*$", "%1"))
          local filePath = (m[2] or ""):gsub("\\", path.sep):gsub("^%s*(.-)%s*$", "%1")
          -- filePath = filePath:gsub("/%d+$", "")
          -- filePath = path_utils.normalize_path(filePath)
          proj:addFile(fileName, filePath)
        end
        line = self:_readLine()
      end
    elseif line:match("^ProjectSection%(ProjectDependencies%)") then
      line = self:_readLine()
      while line and not line:match("^EndProjectSection") do
        local m = { line:match("^(.*)%=(.*)$") }
        if #m >= 1 then
          local parentGuid = (m[1] or ""):gsub("^%s*(.-)%s*$", "%1")
          proj:addDependency(parentGuid)
        end
        line = self:_readLine()
      end
    elseif line:match("^ProjectSection%(WebsiteProperties%)") then
      line = self:_readLine()
      while line and not line:match("^EndProjectSection") do
        local m = { line:match("^(.*)%=(.*)$") }
        if #m >= 2 then
          local propertyName = (m[1] or ""):gsub("^%s*(.-)%s*$", "%1")
          local propertyValue = (m[2] or ""):gsub("^%s*(.-)%s*$", "%1")
          proj:addWebProperty(propertyName, propertyValue)
        end
        line = self:_readLine()
      end
    end
  end
end

function SolutionFile:_parseFirstProjectLine(firstLine, proj)
  local projectPattern = 'Project%("(.-)"%)%s*=%s*"(.-)"%s*,%s*"(.-)"%s*,%s*"(.-)"'
  local guid, name, relPath, pGuid = firstLine:match(projectPattern)

  if guid and name and relPath and pGuid then
    local normalized_path = Path:new(self._folderPath):joinpath(relPath):normalize()
    proj.projectTypeId = guid
    proj.projectName = name
    proj.relativePath = relPath
    proj.fullPath = normalized_path
    proj.projectGuid = pGuid
  end

  self._projects[proj.projectGuid] = proj

  if
    (proj.projectTypeId == vbProjectGuid)
    or (proj.projectTypeId == csProjectGuid)
    or (proj.projectTypeId == cpsProjectGuid)
    or (proj.projectTypeId == cpsCsProjectGuid)
    or (proj.projectTypeId == cpsVbProjectGuid)
    or (proj.projectTypeId == fsProjectGuid)
    or (proj.projectTypeId == cpsFsProjectGuid)
    or (proj.projectTypeId == dbProjectGuid)
    or (proj.projectTypeId == vjProjectGuid)
  then
    proj.projectType = SolutionProjectType.knownToBeMSBuildFormat
  elseif proj.projectTypeId == solutionFolderGuid then
    proj.projectType = SolutionProjectType.solutionFolder
  elseif proj.projectTypeId == vcProjectGuid then
    proj.projectType = SolutionProjectType.knownToBeMSBuildFormat
  elseif proj.projectTypeId == webProjectGuid then
    proj.projectType = SolutionProjectType.webProject
    self._solutionContainsWebProjects = true
  elseif proj.projectTypeId == wdProjectGuid then
    proj.projectType = SolutionProjectType.webDeploymentProject
    self._solutionContainsWebDeploymentProjects = true
  else
    proj.projectType = SolutionProjectType.unknown
  end
end

function SolutionFile:_parseNestedProjects()
  while true do
    local str = self:_readLine()
    if (not str) or (str == "EndGlobalSection") then
      break
    end

    local m = { str:match("^(.-)=(.-)$") }
    if #m >= 2 then
      local projectGuid = m[1]:gsub("^%s*(.-)%s*$", "%1")
      local parentProjectGuid = m[2]:gsub("^%s*(.-)%s*$", "%1")

      local proj = self._projects[projectGuid]
      if proj then
        proj.parentProjectGuid = parentProjectGuid
      end
    end
  end
end

function SolutionFile:_parseSolutionConfigurations()
  while true do
    local str = self:_readLine()
    if (not str) or (str == "EndGlobalSection") then
      break
    end

    if str == "" then
      goto continue
    end
    if str:match("^DESCRIPTION") then
      goto continue
    end

    local equalsPos = str:find("=")
    if equalsPos then
      local fullConfigurationName = str:sub(1, equalsPos - 1):gsub("^%s*(.-)%s*$", "%1")
      local parts = {}
      for w in fullConfigurationName:gmatch("[^|]+") do
        table.insert(parts, w)
      end
      local configuration = parts[1] or ""
      local platform = parts[2] or ""

      local configObj = SolutionConfigurationInSolution:new(configuration, platform)
      table.insert(self._solutionConfigurations, configObj)
    end

    ::continue::
  end
end

function SolutionFile:_parseProjectConfigurations()
  local rawProjectConfigurationsEntries = {}
  while true do
    local str = self:_readLine()
    if (not str) or (str == "EndGlobalSection") then
      break
    end

    if str == "" then
      goto continue
    end

    local kv = { str:match("^(.-)=(.-)$") }
    if #kv >= 2 then
      local key = kv[1]:gsub("^%s*(.-)%s*$", "%1")
      local value = kv[2]:gsub("^%s*(.-)%s*$", "%1")
      rawProjectConfigurationsEntries[key] = value
    end

    ::continue::
  end
  return rawProjectConfigurationsEntries
end

function SolutionFile:_parseVisualStudioVersion(str)
  -- str debería verse como "VisualStudioVersion = 16.0.29519.181"
  local parts = {}
  for w in str:gmatch("[^=]+") do
    table.insert(parts, w)
  end
  return (parts[2] or ""):gsub("^%s*(.-)%s*$", "%1")
end

function SolutionFile:_processProjectConfigurationSection(rawProjectConfigurationsEntries)
  for _, project in pairs(self._projects) do
    if project.projectType ~= SolutionProjectType.solutionFolder then
      for _, solConfig in ipairs(self._solutionConfigurations) do
        -- {GUID}.{configuration}|{platform}.ActiveCfg
        local entryNameActiveConfig = project.projectGuid .. "." .. solConfig.fullName .. ".ActiveCfg"

        -- {GUID}.{configuration}|{platform}.Build.0
        local entryNameBuild = project.projectGuid .. "." .. solConfig.fullName .. ".Build.0"

        local activeCfgVal = rawProjectConfigurationsEntries[entryNameActiveConfig]
        if activeCfgVal then
          local cfgParts = {}
          for w in activeCfgVal:gmatch("[^|]+") do
            table.insert(cfgParts, w)
          end
          local cfg = cfgParts[1] or ""
          local platform = cfgParts[2] or ""

          local hasBuild = rawProjectConfigurationsEntries[entryNameBuild] ~= nil

          local pc = ProjectConfigurationInSolution:new(cfg, platform, hasBuild)
          project:setProjectConfiguration(solConfig.fullName, pc)
        end
      end
    end
  end
end

M.SolutionFile = SolutionFile

return M
