local vim = vim
local Job = require("plenary.job")
local renderer = require("neo-tree.ui.renderer")
local manager = require("neo-tree.sources.manager")
local events = require("neo-tree.events")
local utils = require("neo-tree.utils")
local Path = require("plenary.path")

local solution_file = require("solution_file")
local project_parser = require("project_parser")
local path_utils = require("utils.path")

local M = {
	name = "dotnet_solution",
	display_name = "󰘐 Solution Explorer",
}

local CACHE_EXPIRATION = 300

local ICONS = {
	SOLUTION = "󰘐",
	FOLDER = "",
	PROJECT = "",
	CLASS = "ﴯ",
	INTERFACE = "",
	ENUM = "",
	STRUCT = "",
}

local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function debug_log(message, data)
	-- print(string.format("[Solution Explorer Debug] %s -> %s", message, vim.inspect(data)))
end

local function find_and_parse_solution(state, sln_file_path)
	if (os.time() - state.last_scan) < CACHE_EXPIRATION and state.parsed_solution then
		debug_log("Using cached solution parse", { path = state.solution_path })
		return state.parsed_solution
	end

	state.last_scan = os.time()
	state.parsed_solution = nil
	state.solution_path = nil
	state.project_trees = {}
	state.final_tree = nil
	state.final_tree_path = nil

	state.solution_path = sln_file_path

	local ok, parsed = pcall(solution_file.SolutionFile.parse, sln_file_path)
	if not ok or not parsed then
		print("Error parsing solution: " .. vim.inspect(parsed))
		return nil, "Error parsing solution: " .. tostring(sln_file_path)
	end

	state.parsed_solution = parsed
	return parsed, nil
end

local function build_projects_tree(all_projects)
	local project_by_guid = {}
	local root_projects = {}

	for _, proj in ipairs(all_projects) do
		project_by_guid[proj.projectGuid] = proj
		proj.children = proj.children or {}
	end

	for _, proj in ipairs(all_projects) do
		if proj.parentProjectGuid and project_by_guid[proj.parentProjectGuid] then
			local parent = project_by_guid[proj.parentProjectGuid]
			if parent.projectType == "solutionFolder" then
				table.insert(parent.children, proj)
			else
				table.insert(root_projects, proj)
			end
		else
			table.insert(root_projects, proj)
		end
	end

	return root_projects
end

local function parse_project_safe(proj_path)
	debug_log("Attempting to parse project", { path = proj_path })
	if not proj_path then
		debug_log("Invalid project path", nil)
		return nil
	end

	local ok, result = pcall(function()
		return project_parser.parse_project(proj_path)
	end)

	if not ok then
		debug_log("Error parsing project", { path = proj_path, error = result })
		return nil
	end

	if not result then
		debug_log("Project parser returned nil", { path = proj_path })
		return nil
	end

	debug_log("Successfully parsed project", {
		path = proj_path,
		runtime = result.runtime,
		child_count = result.children and #result.children or 0,
	})
	return result
end

local function create_tree_node(item, project_guid, base_path, known_nodes)
	if not item then
		debug_log("create_tree_node received nil item", { project_guid = project_guid, base_path = base_path })
		return nil
	end

	local full_path = item.full_path
	if not full_path and base_path then
		full_path = path_utils.normalize_path(path_utils.join(base_path, item.name))
	end

	if known_nodes[full_path] then
		debug_log("Duplicate node detected, skipping", { node_id = full_path })
		return nil
	end
	known_nodes[full_path] = true

	local node_type = (item.type == "folder") and "directory" or "file"
	local node = {
		id = full_path or item.name,
		name = item.name,
		path = full_path or item.name,
		type = node_type,
		icon = (item.type == "folder") and ICONS.FOLDER or ICONS.CLASS,
		children = {},
	}

	if item.type == "folder" and item.children then
		for _, child in ipairs(item.children) do
			local child_node = create_tree_node(child, project_guid, full_path, known_nodes)
			if child_node then
				table.insert(node.children, child_node)
			end
		end
	end

	return node
end

local function project_to_node(state, proj, known_nodes)
	if not proj or not proj.fullPath then
		return nil
	end

	proj.fullPath = path_utils.normalize_path(proj.fullPath)
	debug_log("Processing project", {
		name = proj.projectName,
		type = proj.projectType,
		path = proj.fullPath,
	})

	if known_nodes[proj.fullPath] then
		debug_log("Duplicate project node, skipping", { node_id = proj.fullPath })
		return nil
	end
	known_nodes[proj.fullPath] = true

	local node = {
		id = proj.fullPath,
		name = proj.projectName,
		path = proj.fullPath,
		type = "directory",
		icon = (proj.projectType == "solutionFolder") and ICONS.FOLDER or ICONS.PROJECT,
		children = {},
	}

	if
		proj.projectType == "knownToBeMSBuildFormat"
		or proj.projectType == "webProject"
		or proj.projectType == "webDeploymentProject"
	then
		local project_tree = state.project_trees[proj.fullPath]
		if not project_tree then
			project_tree = parse_project_safe(proj.fullPath)
			if project_tree then
				proj.kind = project_tree.kind
				state.project_trees[proj.fullPath] = project_tree
			end
		end

		if project_tree and project_tree.children then
			for _, item in ipairs(project_tree.children) do
				local child_node = create_tree_node(item, proj.projectGuid, proj.fullPath, known_nodes)
				if child_node then
					table.insert(node.children, child_node)
				end
			end
		end
	end

	for _, child_proj in ipairs(proj.children or {}) do
		local child_node = project_to_node(state, child_proj, known_nodes)
		if child_node then
			table.insert(node.children, child_node)
		end
	end

	table.sort(node.children, function(a, b)
		if a.type ~= b.type then
			return a.type == "directory"
		end
		return a.name:lower() < b.name:lower()
	end)

	return node
end

local function build_nodes_from_parsed_solution(state, parsed_solution, base_path)
	local known_nodes = {}

	local solution_node = {
		id = parsed_solution:fullPath(),
		name = "Solution '" .. parsed_solution:name() .. "'",
		path = parsed_solution:fullPath(),
		type = "directory",
		icon = ICONS.SOLUTION,
		children = {},
	}

	local root_projects = build_projects_tree(parsed_solution:projects() or {})
	for _, proj in ipairs(root_projects) do
		local proj_node = project_to_node(state, proj, known_nodes)
		if proj_node then
			table.insert(solution_node.children, proj_node)
		end
	end

	return { solution_node }
end

local function parse_solution(state, base_path, sln_file_path)
	local parsed_solution, err = find_and_parse_solution(state, sln_file_path)
	if not parsed_solution then
		local error = {
			messages = err,
			nodes = {},
		}
		return error
	end

	local items = build_nodes_from_parsed_solution(state, parsed_solution, base_path)

	local data = {
		message = "OK",
		nodes = items,
	}

	return data
end

M.navigate = function(state, path)
	state.path = path or vim.fn.getcwd()

	local workspace = vim.fn.getcwd()

	if state.nodes then
		renderer.show_nodes(state.nodes, state)
		return
	end

	-- local spinner_node = {
	--   id = "dotnet-solution-loading",
	--   name = SPINNER_FRAMES[1] .. " Cargando...",
	--   path = state.path,
	--   type = "message",
	--   children = {},
	-- }
	-- renderer.show_nodes({ spinner_node }, state)
	--

	state.solution_path = nil
	state.parsed_solution = nil
	state.last_scan = 0
	state.project_trees = {}
	state.final_tree = nil
	state.final_tree_path = nil

	Job:new({
		command = "fd",
		args = { "--glob", "*.sln" },
		enable_recording = true,
		on_exit = function(j, return_val)
			if not return_val == 0 then
				print("Error al buscar .sln")
				return
			end
			local job_stdout = j:result()

			local sln_base = nil
			if #job_stdout > 0 then
				sln_base = job_stdout[1]
			end

			print("Solución encontrada: " .. tostring(sln_base))

			if not sln_base then
				local error_node = {
					id = "dotnet-solution-error",
					name = "No se encontró un archivo .sln en el directorio",
					path = state.path,
					type = "file",
					children = {},
				}
				vim.schedule(function()
					renderer.show_nodes({ error_node }, state)
				end)
				return
			end

			local sln_file_path = tostring(Path:new(workspace):joinpath(sln_base))
			vim.schedule(function()
				local data = parse_solution(state, state.path, sln_file_path)

				if not data then
					local error_node = {
						id = "dotnet-solution-error",
						name = "No se encontró un archivo .sln en el directorio",
						path = state.path,
						type = "file",
						children = {},
					}

					renderer.show_nodes({ error_node }, state)
					return
				end

				renderer.show_nodes(data.nodes, state)
			end)
		end,
	}):start()
end

function M.follow_current_file()
	local current_buf = vim.api.nvim_get_current_buf()
	local current_file = vim.api.nvim_buf_get_name(current_buf)
	if not current_file or current_file == "" then
		return
	end

	current_file = utils.normalize_path(current_file)

	local state = require("neo-tree.sources.manager").get_state(M.name)
	if not state or not state.tree or not state.tree.nodes then
		return
	end

	local current_node = state.tree:get_node(current_file)
	if current_node then
		require("neo-tree.ui.renderer").focus_node(state, current_node.id, true)
		require("neo-tree.ui.renderer").expand_to_node(state, current_node.id)

		print("Seguimos el archivo: " .. current_file)
	end
end

M.get_node_stat = function(_)
	return {
		birthtime = { sec = os.time() },
		mtime = { sec = os.time() },
		size = 0,
	}
end

local function get_solution_projects(state)
	if not state.parsed_solution then
		vim.notify("No hay solución cargada", vim.log.levels.WARN)
		return {}
	end

	local projects = {}
	for _, proj in ipairs(state.parsed_solution:projects()) do
		if proj.projectType ~= "solutionFolder" then
			table.insert(projects, {
				value = proj.fullPath,
				display = string.format("%s 󰉋 %s (%s)", ICONS.PROJECT, proj.projectName, proj.kind:upper()),
				ordinal = proj.projectName,
				path = proj.fullPath,
				kind = proj.kind,
			})
		end
	end
	return projects
end

local function find_solution(path)
	local current = vim.fn.expand(path or "%:p:h")
	while current ~= "" do
		local files = vim.fn.glob(current .. "/*.sln", true, 1)
		if #files > 0 then
			return files[1]
		end
		current = vim.fn.fnamemodify(current, ":h")
	end
	return nil
end

local function projects_picker(state)
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values

	pickers
		.new({
			prompt_title = "Proyectos de la Solución",
			finder = finders.new_table({
				results = get_solution_projects(state),
				entry_maker = function(entry)
					return {
						value = entry.value,
						display = entry.display,
						ordinal = entry.ordinal,
						path = entry.path,
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = conf.file_previewer({}),
			attach_mappings = function(prompt_bufnr, map)
				actions.select_default:replace(function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						vim.cmd("edit " .. selection.path)
					end
				end)

				map({ "i", "n" }, "<C-s>", function()
					actions.close(prompt_bufnr)
					local selection = action_state.get_selected_entry()
					if selection then
						state.default_project = {
							path = selection.path,
							name = selection.ordinal,
							kind = selection.kind,
						}
						vim.notify(
							string.format("Proyecto predeterminado: %s (%s)", selection.ordinal, selection.kind:upper())
						)
					end
				end)

				return true
			end,
		}, {})
		:find()
end

vim.api.nvim_create_user_command("SolutionProjects", function()
	local state = require("neo-tree.sources.manager").get_state(M.name)
	if not state.parsed_solution then
		local solution_path = find_solution()
		if solution_path then
			find_and_parse_solution(state, solution_path)
		end
	end
	projects_picker(state)
end, {})

local function get_visual_studio_path()
	local vswhere_path = "C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe"
	if vim.fn.executable(vswhere_path) == 1 then
		local job = Job:new({
			command = vswhere_path,
			args = {
				"-latest",
				"-products",
				"*",
				"-requires",
				"Microsoft.Component.MSBuild",
				"-property",
				"installationPath",
			},
		})
		job:sync()
		return job:result()[1]
	end

	local versions = {
		"2022",
		"2019",
		"2017",
		"2015",
	}

	for _, version in ipairs(versions) do
		local path = ("C:\\Program Files (x86)\\Microsoft Visual Studio\\%s\\Enterprise"):format(version)
		if vim.fn.isdirectory(path) == 1 then
			return path
		end
	end

	return nil
end

local function find_msbuild()
	local vs_path = get_visual_studio_path()
	if vs_path then
		local msbuild_path = Path:new(vs_path):joinpath("MSBuild", "Current", "Bin", "MSBuild.exe"):absolute()

		if vim.fn.filereadable(msbuild_path) == 1 then
			return msbuild_path
		end
	end

	local framework_paths = {
		"C:\\Windows\\Microsoft.NET\\Framework64\\v4.0.30319\\MSBuild.exe",
		"C:\\Windows\\Microsoft.NET\\Framework\\v4.0.30319\\MSBuild.exe",
	}

	for _, path in ipairs(framework_paths) do
		if vim.fn.filereadable(path) == 1 then
			return path
		end
	end

	return nil
end

local function install_build_tools()
	local temp_dir = os.getenv("TEMP") or "C:\\Temp"
	local installer_path = Path:new(temp_dir):joinpath("vs_buildtools.exe")

	print("Descargando Build Tools...")
	local download_job = Job:new({
		command = "powershell",
		args = {
			"-Command",
			("Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile '%s'"):format(
				installer_path
			),
		},
		on_exit = function(j, code)
			if code == 0 then
				print("Instalando Build Tools... (Esto puede tomar varios minutos)")
				local install_job = Job:new({
					command = installer_path,
					args = {
						"--quiet",
						"--norestart",
						"--wait",
						"--add",
						"Microsoft.VisualStudio.Workload.MSBuildTools",
						"--add",
						"Microsoft.VisualStudio.Workload.NetCoreBuildTools",
						"--add",
						"Microsoft.Net.Component.4.8.SDK",
					},
					on_exit = function(_, install_code)
						if install_code == 0 then
							print("Build Tools instalado correctamente!")
							vim.schedule(function()
								M.build_and_run()
							end)
						else
							vim.notify("Error en la instalación", vim.log.levels.ERROR)
						end
					end,
				})
				install_job:start()
			else
				vim.notify("Error al descargar Build Tools", vim.log.levels.ERROR)
			end
		end,
	})
	download_job:start()
end

local function build_project(msbuild_path, project_info)
	local project_path = project_info.path
	vim.notify(string.format("Compilando %s (%s)...", project_info.name, project_info.kind:upper()))

	local build_job = Job:new({
		command = msbuild_path,
		args = {
			project_path,
			"/t:Rebuild",
			"/p:Configuration=Debug",
			"/p:Platform=AnyCPU",
			"/v:minimal",
		},
		on_stdout = function(_, data)
			print(data)
		end,
		on_stderr = function(_, data)
			vim.notify(data, vim.log.levels.ERROR)
		end,
		on_exit = function(_, code)
			if code == 0 then
				vim.notify("✓ Compilación exitosa!", vim.log.levels.INFO)
				M.run_project(project_info)
			else
				vim.notify("✗ Error en la compilación", vim.log.levels.ERROR)
			end
		end,
	})
	build_job:start()
end

local function get_iis_express_path()
	local program_files = os.getenv("ProgramFiles(x86)") or os.getenv("ProgramFiles")
	local paths = {
		Path:new(program_files, "IIS Express", "iisexpress.exe"),
		Path:new("C:", "Program Files (x86)", "IIS Express", "iisexpress.exe"),
		Path:new("C:", "Program Files", "IIS Express", "iisexpress.exe"),
	}

	for _, path in ipairs(paths) do
		if path:exists() then
			return path:absolute()
		end
	end
	return nil
end

local function run_web_project(project_path)
	local iis_path = get_iis_express_path()
	if not iis_path then
		vim.notify("IIS Express no encontrado", vim.log.levels.ERROR)
		return
	end

	local project_dir = Path:new(project_path):parent():absolute()
	local config_path = Path:new(project_dir, "..", ".vs", "config", "applicationhost.config")

	if not config_path:exists() then
		config_path = Path:new(os.getenv("TEMP"), "neo-tree-iis-config.config")

		local config_content = string.format(
			[[
            <configuration>
                <system.applicationHost>
                    <sites>
                        <site name="WebApp" id="1">
                            <application path="/" applicationPool="Clr4IntegratedAppPool">
                                <virtualDirectory path="/" physicalPath="%s" />
                            </application>
                            <bindings>
                                <binding protocol="http" bindingInformation="*:8080:localhost" />
                            </bindings>
                        </site>
                    </sites>
                </system.applicationHost>
            </configuration>
        ]],
			project_dir
		)

		config_path:write(config_content, "w")
	end

	local cmd =
		string.format('"%s" /config:"%s" /site:WebApp /apppool:Clr4IntegratedAppPool', iis_path, config_path:absolute())

	vim.fn.termopen(cmd)
end

function M.run_project(project_info)
	local project_path = project_info.path
	local project_dir = Path:new(project_path):parent():absolute()

	if project_info.kind == "console" or project_info.kind == "winforms" then
		-- Lógica existente para ejecutables
		local output_dir = Path:new(project_dir, "bin", "Debug")
		local exe_files = vim.fn.glob(output_dir:absolute() .. "/*.exe", true, true)

		if #exe_files > 0 then
			vim.fn.termopen('"' .. exe_files[1] .. '"')
		else
			vim.notify("No se encontró el ejecutable compilado", vim.log.levels.WARN)
		end
	elseif project_info.kind == "web" then
		run_web_project(project_path)
	elseif project_info.kind == "library" then
		vim.notify("No se puede ejecutar una biblioteca de clases", vim.log.levels.ERROR)
	else
		vim.notify('Tipo de proyecto "' .. project_info.kind .. '" no soportado', vim.log.levels.WARN)
	end
end

function M.build_and_run()
	local state = require("neo-tree.sources.manager").get_state(M.name)
	local project_info = state.default_project
	if not project_info or not project_info.path then
		vim.notify("No hay proyecto seleccionado", vim.log.levels.ERROR)
		return
	end

	if project_info.kind == "library" then
		vim.notify("No se puede ejecutar una biblioteca de clases", vim.log.levels.ERROR)
		return
	end

	local msbuild_path = find_msbuild()
	if not msbuild_path then
		vim.ui.select({ "Sí", "No" }, {
			prompt = "MSBuild no encontrado. ¿Instalar Build Tools?",
		}, function(choice)
			if choice == "Sí" then
				install_build_tools()
			end
		end)
		return
	end

	build_project(msbuild_path, project_info) -- Pasamos el objeto completo
end

-- Comando de usuario
vim.api.nvim_create_user_command("DotNetFrameworkRun", M.build_and_run, {})

-- Autodetección de entorno al cargar el plugin
vim.schedule(function()
	if vim.fn.has("win32") == 1 then
		local msbuild = find_msbuild()
		if not msbuild then
			vim.notify("Requerido: Visual Studio Build Tools para proyectos .NET Framework", vim.log.levels.WARN)
		end
	end
end)

M.setup = function(config, global_config)
	utils.register_stat_provider("solution-explorer", M.get_node_stat)

	manager.subscribe(M.name, {
		event = events.FS_EVENT,
		handler = function(e)
			-- debug_log("Se detectó cambio: " .. vim.inspect(e), nil)
			-- if e.path and e.path:find(watch_dir, 1, true) then
			--   debug_log("Detectado cambio en .nvim/solution_explorer => refresh", e.path)
			--   state.final_tree = nil
			--   state.final_tree_path = nil
			--   state.last_scan = 0
			--   manager.refresh(M.name)
			-- end
		end,
	})

	if config.follow_current_file.enabled then
		manager.subscribe(M.name, {
			event = events.VIM_BUFFER_ENTER,
			handler = function(args)
				if utils.is_real_file(args.afile) then
					M.follow_current_file()
				end
			end,
		})
	end
end

return M
