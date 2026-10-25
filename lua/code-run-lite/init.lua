-- lua/runlite/init.lua

local M = {}

-- ============================================================
-- 配置
-- ============================================================
M.config = {
	-- snacks.nvim 集成
	snacks = {
		enabled = true,
		key = "<Leader>ce", -- 在 picker 中运行选中文件
		close_picker_on_run = true, -- 运行后关闭 picker，避免浮窗遮住底部输出
		output_height = 12, -- 底部输出 split 高度（行）
	},

	-- Scratchpad
	scratchpad = {
		key = "<CR>", -- normal 模式下按回车运行
		border = "rounded",
		width = 0.8,
		output_height = 12, -- 底部输出 split 高度（行）
	},

	-- 各语言运行器
	runners = {
		python = { cmd = "python3", ext = ".py" },
		javascript = { cmd = "node", ext = ".js" },
		go = { cmd = "go run", ext = ".go" },
		csharp = { cmd = "dotnet-script", ext = ".csx" },
		cs = { cmd = "dotnet-script", ext = ".csx" },
	},
}

-- 复用 run_file 的输出窗口
M.last_output_win = nil
M.last_output_buf = nil

-- Scratchpad 状态
local scratchpad_state = {
	edit_buf = nil,
	output_buf = nil,
	edit_win = nil,
	output_win = nil,
	filetype = nil,
}

-- ============================================================
-- 工具函数
-- ============================================================

local function get_snacks()
	local ok, snacks = pcall(require, "snacks")
	if not ok then
		vim.notify("runlite: snacks.nvim 未安装", vim.log.levels.WARN)
		return nil
	end
	return snacks
end

local function get_runner(filetype)
	if not filetype then
		return nil
	end
	filetype = filetype:lower()
	if filetype == "csharp" then
		filetype = "cs"
	end
	return M.config.runners[filetype] or M.config.runners[filetype == "cs" and "csharp" or filetype]
end

local function filetype_from_path(path)
	local ext = vim.fn.fnamemodify(path, ":e"):lower()
	local map = {
		py = "python",
		js = "javascript",
		ts = "typescript",
		go = "go",
		csx = "cs",
		cs = "cs",
	}
	return map[ext]
end

--- 根据 filetype 构造运行命令
local function build_cmd(filetype, path)
	if filetype == "go" then
		return { "go", "run", path }
	elseif filetype == "cs" or filetype == "csharp" then
		return { "dotnet-script", path }
	elseif filetype == "python" then
		return { "python3", path }
	elseif filetype == "javascript" then
		return { "node", path }
	end
	return nil
end

--- 切到非浮窗窗口（如果当前是浮窗）
local function focus_non_float_win()
	local cur = vim.api.nvim_get_current_win()
	if vim.api.nvim_win_get_config(cur).relative == "" then
		return
	end
	for _, w in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(w).relative == "" then
			vim.api.nvim_set_current_win(w)
			return
		end
	end
end

--- 打开 / 复用底部输出 split（用于 run_file）
---@return integer winid
---@return integer bufnr
local function open_bottom_output(height)
	if M.last_output_win and vim.api.nvim_win_is_valid(M.last_output_win) then
		vim.api.nvim_win_set_height(M.last_output_win, height or 12)
		return M.last_output_win, M.last_output_buf
	end

	focus_non_float_win()
	vim.cmd("botright split")
	local win = vim.api.nvim_get_current_win()

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].filetype = "runlite_output"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].modifiable = false

	vim.api.nvim_win_set_buf(win, buf)
	vim.api.nvim_win_set_height(win, height or 12)

	M.last_output_win = win
	M.last_output_buf = buf
	return win, buf
end

--- 异步执行命令并将输出追加到 output_buf
local function run_command(cmd, output_buf, on_exit)
	vim.api.nvim_buf_set_lines(output_buf, 0, -1, false, {})
	vim.bo[output_buf].modifiable = true

	local function append(lines)
		if not vim.api.nvim_buf_is_valid(output_buf) then
			return
		end
		vim.api.nvim_buf_set_lines(output_buf, -1, -1, false, lines)
	end

	vim.fn.jobstart(cmd, {
		stdout_buffered = false,
		stderr_buffered = false,
		on_stdout = function(_, data)
			if data then
				append(data)
			end
		end,
		on_stderr = function(_, data)
			if data then
				append(data)
			end
		end,
		on_exit = function(_, code)
			append({ "", ("[runlite] 退出码: %d"):format(code) })
			vim.bo[output_buf].modifiable = false
			if on_exit then
				on_exit(code)
			end
		end,
	})
end

--- 为 scratch buffer 手动附加 LSP
local function attach_lsp(bufnr, filetype)
	local clients = vim.lsp.get_clients({ bufnr = bufnr })
	if #clients > 0 then
		return
	end

	local ok, lspconfig = pcall(require, "lspconfig")
	local config
	if ok and lspconfig[filetype] then
		local conf = lspconfig[filetype]
		if type(conf) == "table" and conf.document_config then
			config = conf.document_config.default_config
		end
	end
	if not config and vim.lsp.config then
		config = vim.lsp.config[filetype]
	end

	if not config then
		vim.notify(("runlite: 未找到 %s 的 LSP 配置"):format(filetype), vim.log.levels.WARN)
		return
	end

	local start_config = vim.deepcopy(config)
	start_config.name = start_config.name or filetype
	start_config.filetypes = start_config.filetypes or { filetype }
	start_config.root_dir = start_config.root_dir or function()
		return vim.fn.getcwd()
	end

	vim.lsp.start(start_config, { bufnr = bufnr })
end

-- ============================================================
-- Scratchpad
-- ============================================================

function M.open_scratchpad(filetype)
	filetype = filetype or "python"

	if scratchpad_state.edit_win and vim.api.nvim_win_is_valid(scratchpad_state.edit_win) then
		vim.api.nvim_set_current_win(scratchpad_state.edit_win)
		return
	end

	local runner = get_runner(filetype)
	if not runner then
		vim.notify(("runlite: 不支持的语言 %s"):format(filetype), vim.log.levels.ERROR)
		return
	end

	local ui = vim.api.nvim_list_uis()[1]
	local screen_h = ui and ui.height or 40
	local screen_w = ui and ui.width or 120

	local output_h = math.min(M.config.scratchpad.output_height or 12, math.floor(screen_h * 0.4))

	-- 1. 先打开底部输出 split（真 split，不是浮窗）
	vim.cmd("botright split")
	local output_win = vim.api.nvim_get_current_win()
	local output_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[output_buf].filetype = "runlite_output"
	vim.bo[output_buf].bufhidden = "wipe"
	vim.bo[output_buf].modifiable = false
	vim.api.nvim_win_set_buf(output_win, output_buf)
	vim.api.nvim_win_set_height(output_win, output_h)

	-- 2. 编辑浮窗放在上方区域，避免遮挡底部输出
	local edit_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[edit_buf].filetype = filetype
	vim.bo[edit_buf].bufhidden = "wipe"
	vim.bo[edit_buf].swapfile = false

	local float_width = math.floor(screen_w * (M.config.scratchpad.width or 0.8))
	local available_h = screen_h - output_h - 4
	local float_height = math.min(available_h, math.floor(screen_h * 0.6))
	if float_height < 10 then
		float_height = math.max(10, math.floor(screen_h * 0.5))
	end

	local edit_win = vim.api.nvim_open_win(edit_buf, true, {
		relative = "editor",
		width = float_width,
		height = float_height,
		row = 2,
		col = math.floor((screen_w - float_width) / 2),
		style = "minimal",
		border = M.config.scratchpad.border or "rounded",
		title = (" Scratchpad [%s]  <CR> 运行  q 关闭 "):format(filetype),
		title_pos = "center",
	})

	vim.wo[edit_win].wrap = false
	vim.wo[edit_win].number = false
	vim.wo[edit_win].relativenumber = false
	vim.wo[edit_win].signcolumn = "no"

	attach_lsp(edit_buf, filetype)

	scratchpad_state = {
		edit_buf = edit_buf,
		output_buf = output_buf,
		edit_win = edit_win,
		output_win = output_win,
		filetype = filetype,
	}

	-- 编辑区：normal 模式 <CR> 运行
	vim.keymap.set("n", M.config.scratchpad.key, function()
		M.run_scratchpad()
	end, { buffer = edit_buf, desc = "runlite: 运行 scratchpad" })

	vim.keymap.set("n", "q", function()
		M.close_scratchpad()
	end, { buffer = edit_buf, desc = "runlite: 关闭 scratchpad" })

	-- 输出区：q 关闭
	vim.keymap.set("n", "q", function()
		M.close_scratchpad()
	end, { buffer = output_buf, desc = "runlite: 关闭 scratchpad" })

	vim.api.nvim_set_current_win(edit_win)
end

function M.run_scratchpad()
	local state = scratchpad_state
	if not state.edit_buf or not vim.api.nvim_buf_is_valid(state.edit_buf) then
		vim.notify("runlite: scratchpad 未打开", vim.log.levels.WARN)
		return
	end

	local filetype = state.filetype
	local runner = get_runner(filetype)
	if not runner then
		vim.notify(("runlite: 不支持的语言 %s"):format(filetype), vim.log.levels.ERROR)
		return
	end

	local lines = vim.api.nvim_buf_get_lines(state.edit_buf, 0, -1, false)
	local tmp = vim.fn.tempname() .. runner.ext
	vim.fn.writefile(lines, tmp)

	local cmd = build_cmd(filetype, tmp)
	if not cmd then
		vim.notify(("runlite: 未配置运行命令: %s"):format(filetype), vim.log.levels.ERROR)
		return
	end

	run_command(cmd, state.output_buf, function(_)
		vim.schedule(function()
			vim.fn.delete(tmp)
		end)
	end)
end

function M.close_scratchpad()
	if scratchpad_state.edit_win and vim.api.nvim_win_is_valid(scratchpad_state.edit_win) then
		vim.api.nvim_win_close(scratchpad_state.edit_win, true)
	end
	if scratchpad_state.output_win and vim.api.nvim_win_is_valid(scratchpad_state.output_win) then
		vim.api.nvim_win_close(scratchpad_state.output_win, true)
	end
	scratchpad_state = {
		edit_buf = nil,
		output_buf = nil,
		edit_win = nil,
		output_win = nil,
		filetype = nil,
	}
end

-- ============================================================
-- 运行文件（底部 split 显示输出）
-- ============================================================

function M.run_file(path)
	if not path or path == "" then
		vim.notify("runlite: 未提供文件路径", vim.log.levels.WARN)
		return
	end

	local filetype = filetype_from_path(path)
	if not filetype then
		vim.notify(("runlite: 无法识别文件类型: %s"):format(path), vim.log.levels.WARN)
		return
	end

	local runner = get_runner(filetype)
	if not runner then
		vim.notify(("runlite: 不支持的文件类型: %s"):format(filetype), vim.log.levels.ERROR)
		return
	end

	local cmd = build_cmd(filetype, path)
	if not cmd then
		vim.notify(("runlite: 未配置运行命令: %s"):format(filetype), vim.log.levels.ERROR)
		return
	end

	local win, output_buf = open_bottom_output(M.config.snacks.output_height or 12)

	vim.keymap.set("n", "q", function()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end, { buffer = output_buf, desc = "关闭输出窗口" })

	run_command(cmd, output_buf)
end

-- ============================================================
-- snacks.nvim 集成
-- ============================================================

local function inject_snacks()
	local snacks = get_snacks()
	if not snacks then
		return
	end

	snacks.setup({
		picker = {
			actions = {
				runlite_run = function(picker, item)
					if not (item and item.file) then
						return
					end
					local file = item.file
					if M.config.snacks.close_picker_on_run then
						picker:close()
						vim.schedule(function()
							M.run_file(file)
						end)
					else
						M.run_file(file)
					end
				end,
			},
			win = {
				-- input 窗口：插入/普通模式都支持
				input = {
					keys = {
						[M.config.snacks.key] = { "runlite_run", mode = { "n", "i" } },
					},
				},
				-- list 窗口：普通模式
				list = {
					keys = {
						[M.config.snacks.key] = { "runlite_run", mode = { "n" } },
					},
				},
			},
		},
	})
end

-- ============================================================
-- setup
-- ============================================================

function M.setup(opts)
	M.config = vim.tbl_deep_extend("force", M.config, opts or {})

	vim.api.nvim_create_user_command("RunLiteScratchpad", function(args)
		local ft = args.args ~= "" and args.args or "python"
		M.open_scratchpad(ft)
	end, {
		nargs = "?",
		complete = function()
			return { "python", "javascript", "go", "cs" }
		end,
		desc = "打开 runlite scratchpad",
	})

	vim.api.nvim_create_user_command("RunLiteRunFile", function(args)
		M.run_file(args.args)
	end, {
		nargs = 1,
		complete = "file",
		desc = "运行指定文件",
	})

	vim.keymap.set("n", "<leader>rs", function()
		M.open_scratchpad("python")
	end, { desc = "runlite: Python scratchpad" })
	vim.keymap.set("n", "<leader>rj", function()
		M.open_scratchpad("javascript")
	end, { desc = "runlite: JavaScript scratchpad" })
	vim.keymap.set("n", "<leader>rg", function()
		M.open_scratchpad("go")
	end, { desc = "runlite: Go scratchpad" })
	vim.keymap.set("n", "<leader>rc", function()
		M.open_scratchpad("cs")
	end, { desc = "runlite: C# scratchpad" })

	if M.config.snacks.enabled then
		inject_snacks()
	end
end

return M
