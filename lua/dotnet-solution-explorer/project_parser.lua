local uv = vim.loop
local Path = require("plenary.path")
local ok_xml2lua, xml2lua = pcall(require, "xml2lua")
if not ok_xml2lua then
       xml2lua = nil
end
local path_utils = require("utils.path")

local M = {}

local function normalize_path(path)
	local real = uv.fs_realpath(path)
	if not real then
		real = vim.fn.fnamemodify(path, ":p")
	end
	if real:sub(-1) == Path.path.sep then
		real = real:sub(1, -2)
	end
	if Path.path.sep == "\\" then
		real = real:lower()
	end
	return real
end

local function check_in_base(base_path, final_path)
	local norm_base = normalize_path(base_path)
	if not norm_base then
		return nil, false
	end

	local norm_final = normalize_path(final_path)
	if not norm_final then
		return nil, false
	end

	if norm_final:sub(1, #norm_base) == norm_base then
		local next_char = norm_final:sub(#norm_base + 1, #norm_base + 1)
		if next_char == "" or next_char == Path.path.sep then
			return norm_final, true
		end
	end

	return norm_final, false
end

-- Función auxiliar para leer archivo
local function read_file(filepath)
	local lines = vim.fn.readfile(filepath)
	return table.concat(lines, "\n")
end

-- Detecta el runtime y tipo de proyecto desde el XML
local function detect_project_type(project_node)
	local project_info = {
		is_sdk_style = false,
		runtime = nil,
	}

	-- Detectar SDK style
	if project_node._attr and project_node._attr.Sdk then
		project_info.is_sdk_style = true

		-- Buscar TargetFramework en PropertyGroup
		if project_node.PropertyGroup then
			local groups = type(project_node.PropertyGroup) == "table" and project_node.PropertyGroup
				or { project_node.PropertyGroup }

			for _, group in ipairs(groups) do
				if group.TargetFramework then
					project_info.runtime = group.TargetFramework
					break
				elseif group.TargetFrameworkVersion then
					-- Convertir "v4.7.2" a "net472"
					local version = group.TargetFrameworkVersion:match("v(%d+%.%d+%.?%d*)")
					if version then
						project_info.runtime = "net" .. version:gsub("%.", "")
					end
					break
				end
			end
		end
	else
		-- Proyecto .NET Framework tradicional
		if project_node.PropertyGroup then
			local groups = type(project_node.PropertyGroup) == "table" and project_node.PropertyGroup
				or { project_node.PropertyGroup }

			for _, group in ipairs(groups) do
				if group.TargetFrameworkVersion then
					local version = group.TargetFrameworkVersion:match("v(%d+%.%d+%.?%d*)")
					if version then
						project_info.runtime = "net" .. version:gsub("%.", "")
					end
					break
				end
			end
		end
	end

	return project_info
end

local function scan_directory(proj_dir)
	local files = {}
	local function scan(dir)
		local items = vim.fn.globpath(dir, "*", false, 1)
		for _, item in ipairs(items) do
			local stat = vim.loop.fs_stat(item)
			if stat then
				local name = vim.fn.fnamemodify(item, ":t")
				local is_excluded = name:match("^%.")
					or name:match("^node_modules$")
					or name:match("^bin$")
					or name:match("^obj$")

				if not is_excluded then
					if stat.type == "directory" then
						scan(item)
					elseif stat.type == "file" then
						local file_type_supported = { "%.json$", "%.cs$", "%.razor$", "%.cshtml$" }
						for _, file_type in ipairs(file_type_supported) do
							if name:match(file_type) then
								table.insert(files, {
									type = "class",
									name = name,
									full_path = item,
								})
								break
							end
						end
					end
				end
			end
		end
	end

	scan(proj_dir)
	return files
end

local function build_tree(files, base_dir)
	local root = {
		children = {},
	}

	local function add_to_tree(file)
		local _, in_base = check_in_base(base_dir, file.full_path)

		local file_name = vim.fn.fnamemodify(file.full_path, ":t")
		local parts = { file_name }
		if in_base then
			local rel_path = file.full_path:gsub("^" .. vim.pesc(base_dir .. Path.path.sep), "")
			parts = vim.split(rel_path, Path.path.sep)
		end

		local current = root
		for i = 1, #parts - 1 do
			local folder_name = parts[i]
			local found = false

			for _, child in ipairs(current.children) do
				if child.type == "folder" and child.name == folder_name then
					current = child
					found = true
					break
				end
			end

			if not found then
				local new_folder = {
					type = "folder",
					name = folder_name,
					full_path = base_dir .. Path.path.sep .. table.concat(parts, Path.path.sep, 1, i),
					children = {},
				}
				table.insert(current.children, new_folder)
				current = new_folder
			end
		end

		table.insert(current.children, {
			type = "class",
			full_path = file.full_path,
			name = parts[#parts],
		})
	end

	for _, file in ipairs(files) do
		add_to_tree(file)
	end

	return root
end

local function parse_framework_style(base_dir, project_node)
	local files = {}

	local function process_node(group, node_name, use_absolute)
		if group[node_name] then
			local items = type(group[node_name]) == "table" and group[node_name] or { group[node_name] }

			for _, item in ipairs(items) do
				if item._attr and item._attr.Include then
					local path = Path:new(base_dir):joinpath(item._attr.Include)
					if use_absolute then
						path = path:absolute()
					end

					table.insert(files, {
						type = "class",
						name = vim.fn.fnamemodify(item._attr.Include, ":t"),
						full_path = tostring(path),
					})
				end
			end
		end
	end

	if project_node.ItemGroup then
		local groups = type(project_node.ItemGroup) == "table" and project_node.ItemGroup or { project_node.ItemGroup }

		local node_configs = {
			{ name = "Compile", use_absolute = false },
			{ name = "None", use_absolute = true },
			{ name = "EmbeddedResource", use_absolute = true },
		}

		for _, group in ipairs(groups) do
			for _, config in ipairs(node_configs) do
				process_node(group, config.name, config.use_absolute)
			end
		end
	end

	return files
end

local function detect_project_kind(project_node)
	local is_web = false
	local output_type = "library"

	if project_node.PropertyGroup then
		local groups = type(project_node.PropertyGroup) == "table" and project_node.PropertyGroup
			or { project_node.PropertyGroup }

		for _, group in ipairs(groups) do
			if group.OutputType then
				output_type = group.OutputType:lower()
			end

			if group.AspNetCompiler then
				is_web = true
			end
		end
	end

	if project_node.ItemGroup then
		local groups = type(project_node.ItemGroup) == "table" and project_node.ItemGroup or { project_node.ItemGroup }

		for _, group in ipairs(groups) do
			if group.Reference then
				local references = type(group.Reference) == "table" and group.Reference or { group.Reference }

				for _, ref in ipairs(references) do
					if ref._attr and ref._attr.Include then
						local include = ref._attr.Include:lower()
						if include:match("system.web") then
							is_web = true
						end
					end
				end
			end
		end
	end

	if project_node.ItemGroup then
		local groups = type(project_node.ItemGroup) == "table" and project_node.ItemGroup or { project_node.ItemGroup }

		for _, group in ipairs(groups) do
			if group.Content and group.Content._attr and group.Content._attr.Include:match("%.aspx$") then
				is_web = true
			end
		end
	end

	if is_web then
		return "web"
	elseif output_type == "exe" then
		return "console"
	elseif output_type == "winexe" then
		return "winforms"
	else
		return "library"
	end
end

function M.parse_project(proj_path)
       if not xml2lua then
               vim.notify("Falta la dependencia xml2lua. Instálala con 'luarocks install xml2lua'", vim.log.levels.ERROR)
               return nil, "xml2lua missing"
       end

       local handler = require("xmlhandler.tree")
       proj_path = path_utils.normalize_path(proj_path)

	local csproj_handler = handler:new()
	local csproj_parser = xml2lua.parser(csproj_handler)
	local content = read_file(proj_path)
	csproj_parser:parse(content)

	if not csproj_handler.root or not csproj_handler.root.Project then
		return nil, "Invalid project file"
	end
	local project_node = csproj_handler.root.Project
	local project_info = detect_project_type(project_node)

	local base_dir = tostring(Path:new(proj_path):parent())
	local files

	if project_info.is_sdk_style then
		files = scan_directory(base_dir)
	else
		files = parse_framework_style(base_dir, project_node)
	end

	local tree = build_tree(files, base_dir)

        return {
                runtime = project_info.runtime,
                kind = detect_project_kind(project_node),
                children = tree.children,
                is_sdk_style = project_info.is_sdk_style,
        }
end

return M
