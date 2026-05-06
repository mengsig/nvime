local agents = require("nvime.agents")
local buffer_guard = require("nvime.buffer_guard")
local git = require("nvime.git")
local progress = require("nvime.progress")
local prompts = require("nvime.prompts")
local provider_api = require("nvime.provider")
local render = require("nvime.render")
local spinner = require("nvime.spinner")
local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local scroll_ns = vim.api.nvim_create_namespace("nvime.chat")
local input_ns = vim.api.nvim_create_namespace("nvime.chat.input")
local focus_group = vim.api.nvim_create_augroup("nvime.chat.focus", { clear = false })

local INPUT_PROMPT_LINE = 1
local sessions_loaded = false
local save_pending = false
local active_session

local function sessions_config()
	return (state.config or {}).sessions or {}
end

local function sessions_enabled()
	return sessions_config().enabled ~= false
end

local function sessions_path()
	local cfg = sessions_config()
	if cfg.chat_path and cfg.chat_path ~= "" then
		return vim.fn.fnamemodify(cfg.chat_path, ":p")
	end
	if cfg.path and cfg.path ~= "" then
		return vim.fn.fnamemodify(cfg.path, ":p:h") .. "/chat-sessions.json"
	end

	local root = git.root()
	if root then
		return root .. "/.nvime/chat-sessions.json"
	end

	return vim.fn.stdpath("state") .. "/nvime/chat-sessions.json"
end

local function notify_persist_error(err)
	vim.schedule(function()
		vim.notify("nvime could not persist chat sessions: " .. tostring(err), vim.log.levels.WARN)
	end)
end

local function now()
	return os.time()
end

local function persisted_lines(session)
	if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
		return vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false)
	end
	return session.lines or {}
end

local function serializable_session(session)
	return {
		id = session.id,
		title = session.title,
		provider = session.provider,
		history = session.history or {},
		input_start = session.input_start,
		provider_sessions = session.provider_sessions or {},
		provider_workspaces = session.provider_workspaces or {},
		last_provider = session.last_provider,
		lines = persisted_lines(session),
		created_at = session.created_at,
		updated_at = session.updated_at,
	}
end

local function save_sessions_now()
	if not sessions_enabled() then
		return
	end
	local sessions = state.chat and state.chat.sessions or {}
	local max_sessions = tonumber(sessions_config().max) or 100
	local out = {}
	local sorted = vim.deepcopy(sessions)
	table.sort(sorted, function(left, right)
		return (left.updated_at or 0) > (right.updated_at or 0)
	end)
	for index, session in ipairs(sorted) do
		if index > max_sessions then
			break
		end
		out[#out + 1] = serializable_session(session)
	end

	local path = sessions_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	local fd, err = io.open(path, "w")
	if not fd then
		notify_persist_error(err)
		return
	end
	local ok, write_err = pcall(function()
		local encoded = vim.json.encode({
			version = 1,
			next_session_id = state.chat.next_session_id or 1,
			sessions = out,
		})
		local wrote, err1 = fd:write(encoded)
		if not wrote then
			error(err1 or "write failed")
		end
		wrote, err1 = fd:write("\n")
		if not wrote then
			error(err1 or "write failed")
		end
	end)
	local close_ok, closed, close_err = pcall(function()
		return fd:close()
	end)
	if not ok then
		notify_persist_error(write_err)
	elseif not close_ok then
		notify_persist_error(closed)
	elseif not closed then
		notify_persist_error(close_err)
	end
end

local function schedule_save_sessions()
	if not sessions_enabled() or save_pending then
		return
	end
	save_pending = true
	vim.defer_fn(function()
		save_pending = false
		save_sessions_now()
	end, 150)
end

local function load_sessions()
	if sessions_loaded then
		return
	end
	sessions_loaded = true
	if not sessions_enabled() then
		return
	end

	local path = sessions_path()
	if vim.fn.filereadable(path) ~= 1 then
		return
	end
	local ok, raw = pcall(vim.fn.readfile, path)
	if not ok or not raw or #raw == 0 then
		return
	end
	local decoded_ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
	if not decoded_ok or type(decoded) ~= "table" or type(decoded.sessions) ~= "table" then
		return
	end

	state.chat.sessions = {}
	local max_id = 0
	for _, item in ipairs(decoded.sessions) do
		if type(item) == "table" and item.id then
			item.id = tonumber(item.id)
			if item.id then
				item.title = item.title or ("Chat #" .. tostring(item.id))
				item.history = type(item.history) == "table" and item.history or {}
				item.provider_sessions = type(item.provider_sessions) == "table" and item.provider_sessions or {}
				item.provider_workspaces = type(item.provider_workspaces) == "table" and item.provider_workspaces or {}
				item.lines = type(item.lines) == "table" and item.lines or nil
				item.busy = false
				item.progress = nil
				item.input_active = false
				item.bufnr = nil
				max_id = math.max(max_id, item.id)
				state.chat.sessions[#state.chat.sessions + 1] = item
			end
		end
	end
	state.chat.next_session_id = math.max(tonumber(decoded.next_session_id) or 1, max_id + 1)
end

local function provider()
	local active_id = state.chat and state.chat.active_session_id
	for _, session in ipairs(state.chat and state.chat.sessions or {}) do
		if session.id == active_id and session.provider then
			return session.provider
		end
	end
	return (state.chat and state.chat.provider) or (state.config and state.config.provider) or "claude"
end

local function prompt_prefix()
	return "[" .. provider() .. "]$ "
end

local function chat_config()
	return ((state.config or {}).chat or {})
end

local function line_count(bufnr)
	return vim.api.nvim_buf_line_count(bufnr)
end

local function prompt_end_col(panel)
	if not panel or not panel.input_bufnr or not vim.api.nvim_buf_is_valid(panel.input_bufnr) then
		return #prompt_prefix()
	end
	local lnum = panel.input_start or 1
	local line = vim.api.nvim_buf_get_lines(panel.input_bufnr, lnum - 1, lnum, false)[1] or ""
	return #line
end

local function close_panel()
	local panel = state.panels.chat
	if not panel then
		return
	end
	local seen = {}
	for _, key in ipairs({ "input_winid", "winid" }) do
		local winid = panel[key]
		if winid and not seen[winid] and vim.api.nvim_win_is_valid(winid) then
			seen[winid] = true
			pcall(vim.api.nvim_win_close, winid, true)
		end
	end
end

local function panel_is_open(session_id)
	local panel = state.panels.chat
	return panel
		and panel.winid
		and vim.api.nvim_win_is_valid(panel.winid)
		and (not session_id or panel.session_id == session_id)
end

local function completion_behavior()
	local ui = (state.config or {}).ui or {}
	if ui.completion == "open" or ui.completion == "popup" then
		return "open"
	end
	return "notify"
end

local function notify_finished(session, code)
	if not session or panel_is_open(session.id) then
		return
	end
	state.last_session = { kind = "chat", id = session.id }
	if completion_behavior() == "open" then
		M.open_session(session.id)
		return
	end
	local level = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
	local status = code == 0 and "finished" or ("failed with code " .. tostring(code))
	vim.notify("nvime chat " .. status .. ". Reopen with :NvimeLast or <leader>nn.", level)
end

function M.close()
	close_panel()
end

local function find_buffer_by_name(name)
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
			return bufnr
		end
	end
	return nil
end

local function set_scratch_options(bufnr, filetype)
	vim.bo[bufnr].buftype = "nofile"
	vim.bo[bufnr].bufhidden = "hide"
	vim.bo[bufnr].swapfile = false
	vim.bo[bufnr].filetype = filetype or "nvime"
end

local function ensure_named_buffer(name, filetype)
	local bufnr = find_buffer_by_name(name)
	if not bufnr then
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(bufnr, name)
	end
	set_scratch_options(bufnr, filetype)
	return bufnr
end

local function session_buffer_name(session)
	return "nvime://chat/" .. tostring(session.id)
end

local function sync_legacy_to_session(session)
	if not session then
		return
	end
	if state.chat._legacy_session_id ~= session.id then
		return
	end
	if type(state.chat.history) == "table" and state.chat.history ~= session.history then
		session.history = state.chat.history
	end
	if type(state.chat.provider_sessions) == "table" and state.chat.provider_sessions ~= session.provider_sessions then
		session.provider_sessions = state.chat.provider_sessions
	end
	if
		type(state.chat.provider_workspaces) == "table"
		and state.chat.provider_workspaces ~= session.provider_workspaces
	then
		session.provider_workspaces = state.chat.provider_workspaces
	end
	if state.chat.last_provider ~= nil and state.chat.last_provider ~= session.last_provider then
		session.last_provider = state.chat.last_provider
	end
end

local function sync_session_to_legacy(session)
	if not session then
		return
	end
	state.chat.history = session.history or {}
	state.chat.provider_sessions = session.provider_sessions or {}
	state.chat.provider_workspaces = session.provider_workspaces or {}
	state.chat.last_provider = session.last_provider
	state.chat.provider = session.provider
	state.chat.busy = session.busy == true
	state.chat.progress = session.progress
	state.chat._legacy_session_id = session.id
end

local function ensure_sessions()
	load_sessions()
	state.chat.sessions = state.chat.sessions or {}
	state.chat.next_session_id = state.chat.next_session_id or 1
	return state.chat.sessions
end

local function summarize_title(text)
	text = vim.trim((text or ""):gsub("%s+", " "))
	if text == "" then
		return nil
	end
	if #text > 58 then
		text = text:sub(1, 55) .. "..."
	end
	return text
end

local function touch_session(session)
	if session then
		session.updated_at = now()
		sync_session_to_legacy(session)
		schedule_save_sessions()
	end
end

local function ensure_session_buffer(session)
	if not session then
		return nil
	end
	if not session.bufnr or not vim.api.nvim_buf_is_valid(session.bufnr) then
		session.bufnr = ensure_named_buffer(session_buffer_name(session), "nvime")
		if session.lines and #session.lines > 0 then
			local modifiable = vim.bo[session.bufnr].modifiable
			local readonly = vim.bo[session.bufnr].readonly
			vim.bo[session.bufnr].readonly = false
			vim.bo[session.bufnr].modifiable = true
			vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, session.lines)
			vim.bo[session.bufnr].modifiable = modifiable
			vim.bo[session.bufnr].readonly = readonly
		end
	else
		set_scratch_options(session.bufnr, "nvime")
	end
	return session.bufnr
end

local function create_session(opts)
	opts = opts or {}
	local sessions = ensure_sessions()
	local id = state.chat.next_session_id
	state.chat.next_session_id = id + 1
	local session = {
		id = id,
		title = opts.title or ("Chat #" .. tostring(id)),
		provider = opts.provider or (state.config and state.config.provider) or "claude",
		history = {},
		provider_sessions = {},
		provider_workspaces = {},
		last_provider = nil,
		input_start = nil,
		input_active = false,
		busy = false,
		created_at = now(),
		updated_at = now(),
	}
	ensure_session_buffer(session)
	table.insert(sessions, session)
	state.chat.active_session_id = session.id
	state.last_session = { kind = "chat", id = session.id }
	sync_session_to_legacy(session)
	schedule_save_sessions()
	return session
end

local function get_session(id)
	if not id then
		return nil
	end
	for _, session in ipairs(ensure_sessions()) do
		if session.id == tonumber(id) then
			return session
		end
	end
	return nil
end

active_session = function()
	local session = get_session(state.chat and state.chat.active_session_id)
	if session then
		sync_legacy_to_session(session)
		return session
	end
	return nil
end

local function ensure_active_session()
	return active_session() or create_session()
end

local function sync_active_panel_to_session()
	local panel = state.panels.chat
	local session = active_session()
	if not panel or not session then
		return
	end
	if panel.session_id ~= session.id then
		return
	end
	session.input_start = panel.input_start
	session.input_active = panel.input_active == true
	session.bufnr = panel.bufnr or session.bufnr
	touch_session(session)
end

local function panel_for_session(session)
	local panel = state.panels.chat
	if panel and session and panel.session_id == session.id then
		return panel
	end
	return {
		bufnr = session and session.bufnr,
		input_bufnr = session and session.bufnr,
		input_start = session and session.input_start,
		input_active = false,
	}
end

local function delete_named_buffer(name)
	local bufnr = find_buffer_by_name(name)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
	end
end

local function set_locked(bufnr, locked)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	if locked then
		vim.bo[bufnr].readonly = true
		vim.bo[bufnr].modifiable = false
	else
		vim.bo[bufnr].readonly = false
		vim.bo[bufnr].modifiable = true
	end
end

local function with_writable(bufnr, fn, after, sync_panel)
	local modifiable = vim.bo[bufnr].modifiable
	local readonly = vim.bo[bufnr].readonly
	local ok, result = pcall(function()
		return buffer_guard.suspend(bufnr, function()
			vim.bo[bufnr].readonly = false
			vim.bo[bufnr].modifiable = true
			return fn()
		end)
	end)
	vim.bo[bufnr].modifiable = modifiable
	vim.bo[bufnr].readonly = readonly
	if not ok then
		error(result)
	end
	if after then
		after(bufnr)
	end
	buffer_guard.sync(bufnr, sync_panel or state.panels.chat)
	return result
end

local function dimensions()
	local cfg = (state.config or {}).ui or {}
	local columns = vim.o.columns
	local lines = vim.o.lines
	local width = cfg.width or math.floor(columns * (cfg.float_width or 0.82))
	local height = cfg.height or math.floor(lines * (cfg.float_height or 0.72))

	if type(cfg.float_width) == "number" and cfg.float_width > 0 and cfg.float_width <= 1 then
		width = math.floor(columns * cfg.float_width)
	end
	if type(cfg.float_height) == "number" and cfg.float_height > 0 and cfg.float_height <= 1 then
		height = math.floor(lines * cfg.float_height)
	end

	width = math.max(56, math.min(width, columns - 4))
	height = math.max(16, math.min(height, lines - 4))

	local row = math.floor((lines - height) / 2 - 1)
	local col = math.floor((columns - width) / 2)

	return {
		width = width,
		height = height,
		row = math.max(0, row),
		col = math.max(0, col),
		border = cfg.border or "rounded",
	}
end

local function title()
	return "nvime.nvim"
end

local function scroll_config()
	local dim = dimensions()
	local footer = " i input | ? prompts | <CR> send on prompt | p provider | P choose | q close "
	return {
		relative = "editor",
		width = dim.width,
		height = dim.height,
		row = dim.row,
		col = dim.col,
		style = "minimal",
		border = dim.border,
		title = " " .. title() .. " ",
		title_pos = "center",
		footer = footer,
		footer_pos = "center",
		zindex = 50,
	}
end

local function configure_scrollback_window(winid)
	vim.wo[winid].wrap = true
	vim.wo[winid].number = false
	vim.wo[winid].relativenumber = false
	vim.wo[winid].signcolumn = "no"
	vim.wo[winid].cursorline = false
	vim.wo[winid].spell = false
	vim.wo[winid].winblend = 0
	vim.wo[winid].winhighlight =
		"NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted,WinBar:NvimeNormal"
	vim.wo[winid].winbar = "%{%v:lua.require'nvime.chat'.winbar_text()%}"
end

local function extract_prompt_text(line)
	line = line or ""
	local modern = line:match("^%[[^%]]+%]%$%s*(.*)$")
	if modern then
		return modern
	end
	return vim.trim(line)
end

local function current_input_text()
	local panel = state.panels.chat
	local bufnr = panel and panel.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return ""
	end
	local prompt_lnum = (panel.input_start or line_count(bufnr)) + INPUT_PROMPT_LINE - 1
	local line = vim.api.nvim_buf_get_lines(bufnr, prompt_lnum - 1, prompt_lnum, false)[1] or ""
	return extract_prompt_text(line)
end

local function prompt_has_submit_text(panel)
	if not panel or not panel.input_bufnr or not vim.api.nvim_buf_is_valid(panel.input_bufnr) then
		return false
	end
	if not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
		return false
	end
	local lnum = panel.input_start or 1
	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, panel.winid)
	if not ok or cursor[1] ~= lnum then
		return false
	end
	local line = vim.api.nvim_buf_get_lines(panel.input_bufnr, lnum - 1, lnum, false)[1] or ""
	return vim.trim(extract_prompt_text(line)) ~= ""
end

local function decorate_scrollback(bufnr)
	render.scrollback(bufnr, scroll_ns)
end

local function decorate_input(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	vim.api.nvim_buf_clear_namespace(bufnr, input_ns, 0, -1)
	local panel = state.panels.chat
	local start = panel and panel.input_start
	if not start then
		return
	end
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local prompt_lnum = start + INPUT_PROMPT_LINE - 1
	local prompt_line = lines[prompt_lnum] or ""
	local prefix = prompt_prefix()
	if vim.startswith(prompt_line, prefix) then
		vim.api.nvim_buf_set_extmark(bufnr, input_ns, prompt_lnum - 1, 0, {
			end_col = #prefix,
			hl_group = "NvimeInputPrompt",
		})
		if #prompt_line > #prefix then
			vim.api.nvim_buf_set_extmark(bufnr, input_ns, prompt_lnum - 1, #prefix, {
				end_col = #prompt_line,
				hl_group = "NvimeUserText",
			})
		end
		local rule_width = vim.o.columns
		if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
			rule_width = vim.api.nvim_win_get_width(panel.winid)
		end
		rule_width = math.max(20, rule_width - 2)
		local virt_lines = {}
		local session_for_status = active_session()
		if session_for_status and session_for_status.busy then
			local provider_name = session_for_status.provider or "?"
			local detail = progress.compact(session_for_status.progress or "")
			detail = detail:gsub("^" .. provider_name .. "%s*", "")
			if detail == "" then
				detail = "working"
			end
			local status_text = render.spinner_text() .. "  " .. detail
			local pad = math.max(0, rule_width - vim.fn.strdisplaywidth(status_text))
			virt_lines[#virt_lines + 1] = {
				{ string.rep(" ", pad), "" },
				{ status_text, "NvimeStatusRunning" },
			}
		end
		virt_lines[#virt_lines + 1] = { { string.rep("─", rule_width), "NvimeRule" } }
		vim.api.nvim_buf_set_extmark(bufnr, input_ns, prompt_lnum - 1, 0, {
			virt_lines = virt_lines,
			virt_lines_above = true,
			priority = 80,
		})
	end
	if #prompt_line <= #prefix then
		vim.api.nvim_buf_set_extmark(bufnr, input_ns, prompt_lnum - 1, #prefix, {
			virt_text = { { "type a review/docs prompt", "NvimeInputGhost" } },
			virt_text_pos = "eol",
			priority = 90,
		})
	end
end

local function scroll_to_bottom()
	local panel = state.panels.chat
	if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
		return
	end
	local target = math.max(1, (panel.input_start or line_count(panel.bufnr)))
	local col = 0
	if panel.input_active then
		local ok, cursor = pcall(vim.api.nvim_win_get_cursor, panel.winid)
		if ok then
			col = cursor[2]
		end
	end
	vim.api.nvim_win_set_cursor(panel.winid, { target, col })
end

local function save_window_view(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return nil
	end
	local ok, view = pcall(vim.api.nvim_win_call, winid, vim.fn.winsaveview)
	return ok and view or nil
end

local function restore_window_view(winid, view)
	if not view or not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end
	pcall(vim.api.nvim_win_call, winid, function()
		vim.fn.winrestview(view)
	end)
end

local function view_is_at_bottom(panel)
	if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
		return false
	end
	local view = save_window_view(panel.winid)
	if not view then
		return false
	end
	local height = vim.api.nvim_win_get_height(panel.winid)
	return (view.topline or 1) + height >= line_count(panel.bufnr)
end

local function cursor_is_on_prompt(panel)
	if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
		return false
	end
	local ok, cursor = pcall(vim.api.nvim_win_get_cursor, panel.winid)
	if not ok then
		return false
	end
	return cursor[1] >= (panel.input_start or line_count(panel.bufnr))
end

local function should_auto_scroll(panel)
	if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
		return false
	end
	if panel.input_active == true then
		return true
	end
	return view_is_at_bottom(panel) and cursor_is_on_prompt(panel)
end

local function refresh_header(bufnr)
	decorate_scrollback(bufnr)
end

local function reset_input(text, opts)
	opts = opts or {}
	local panel = state.panels.chat
	local bufnr = panel and panel.bufnr
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	text = text or ""
	local follow = opts.force_follow == true or should_auto_scroll(panel)
	local view = follow and nil or save_window_view(panel.winid)
	with_writable(bufnr, function()
		local start = panel.input_start
		local count = line_count(bufnr)
		if not start or start < 1 or start > count then
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			if count == 1 and lines[1] == "" then
				start = 1
			else
				start = count + 1
			end
		end
		vim.api.nvim_buf_set_lines(bufnr, start - 1, count, false, {
			prompt_prefix() .. text,
		})
		panel.input_start = vim.api.nvim_buf_line_count(bufnr)
	end, decorate_input)
	sync_active_panel_to_session()
	if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
		if follow then
			local prompt_lnum = panel.input_start + INPUT_PROMPT_LINE - 1
			pcall(vim.api.nvim_win_set_cursor, panel.winid, { prompt_lnum, #prompt_prefix() })
			pcall(vim.api.nvim_win_call, panel.winid, function()
				vim.fn.winrestview({ topline = math.max(1, prompt_lnum - vim.api.nvim_win_get_height(panel.winid) + 2) })
			end)
		else
			restore_window_view(panel.winid, view)
		end
	end
end

local function refresh_input()
	reset_input(current_input_text())
	local panel = state.panels.chat
	if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
		vim.api.nvim_win_set_config(panel.winid, scroll_config())
		configure_scrollback_window(panel.winid)
	end
end

local function open_or_configure_window(bufnr, winid, config, configure, enter)
	if winid and vim.api.nvim_win_is_valid(winid) then
		vim.api.nvim_win_set_buf(winid, bufnr)
		vim.api.nvim_win_set_config(winid, config)
		configure(winid)
		if enter then
			vim.api.nvim_set_current_win(winid)
		end
		return winid
	end
	local next_winid = vim.api.nvim_open_win(bufnr, enter == true, config)
	configure(next_winid)
	return next_winid
end

local function in_input_window(panel)
	return panel
		and panel.input_active == true
		and panel.winid
		and vim.api.nvim_win_is_valid(panel.winid)
		and vim.api.nvim_get_current_win() == panel.winid
end

local function focus_scrollback()
	local panel = state.panels.chat
	if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
		panel.input_active = false
		set_locked(panel.bufnr, true)
		vim.api.nvim_set_current_win(panel.winid)
	end
end

local function attach_focus_lock(bufnr)
	pcall(vim.api.nvim_clear_autocmds, { group = focus_group, buffer = bufnr })
	vim.api.nvim_create_autocmd("WinEnter", {
		group = focus_group,
		buffer = bufnr,
		callback = function()
			local panel = state.panels.chat
			if not panel or panel.bufnr ~= bufnr then
				return
			end
			panel.input_active = false
			set_locked(bufnr, true)
		end,
	})
end

local function attach_input_guard(bufnr)
	buffer_guard.attach({
		bufnr = bufnr,
		key = "nvime_chat_guard_attached",
		panel = function()
			return state.panels.chat
		end,
		prompt_lnum = function(panel)
			return panel.input_start or 1
		end,
		prompt_prefix = prompt_prefix,
		in_input_window = in_input_window,
		set_locked = set_locked,
		decorate = function(target)
			decorate_scrollback(target)
			decorate_input(target)
		end,
	})
end

local function attach_panel(bufnr)
	local opts = { buffer = bufnr, silent = true }
	vim.keymap.set("n", "<CR>", function()
		if in_input_window(state.panels.chat) or prompt_has_submit_text(state.panels.chat) then
			require("nvime.chat").submit_current()
		else
			require("nvime.chat").prompt()
		end
	end, opts)
	vim.keymap.set("n", "i", function()
		require("nvime.chat").prompt({ preserve_cursor = true })
	end, opts)
	vim.keymap.set("n", "I", function()
		require("nvime.chat").prompt()
	end, opts)
	vim.keymap.set("n", "a", function()
		require("nvime.chat").prompt({ cursor = "end" })
	end, opts)
	vim.keymap.set("n", "A", function()
		require("nvime.chat").prompt({ cursor = "end" })
	end, opts)
	vim.keymap.set("n", "o", function()
		require("nvime.chat").prompt({ cursor = "end" })
	end, opts)
	vim.keymap.set("n", "O", function()
		require("nvime.chat").prompt({ cursor = "end" })
	end, opts)
	vim.keymap.set("n", "p", function()
		provider_api.cycle({ scope = "chat" })
	end, opts)
	vim.keymap.set("n", "<Tab>", function()
		provider_api.cycle({ scope = "chat" })
	end, opts)
	vim.keymap.set("n", "P", function()
		provider_api.choose({ scope = "chat" })
	end, opts)
	vim.keymap.set("n", "?", function()
		require("nvime.chat").choose_prompt()
	end, opts)
	vim.keymap.set("i", "<CR>", function()
		vim.cmd.stopinsert()
		require("nvime.chat").submit_current()
	end, opts)
	vim.keymap.set("i", "<C-U>", function()
		local panel = state.panels.chat
		if not panel or not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
			return
		end
		local lnum = panel.input_start or 1
		local prefix = prompt_prefix()
		buffer_guard.suspend(panel.bufnr, function()
			vim.api.nvim_buf_set_lines(panel.bufnr, lnum - 1, lnum, false, { prefix })
		end)
		buffer_guard.sync(panel.bufnr, panel)
		if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
			pcall(vim.api.nvim_win_set_cursor, panel.winid, { lnum, #prefix })
		end
	end, opts)
	vim.keymap.set("n", "<Esc>", function()
		focus_scrollback()
	end, opts)
	vim.keymap.set("n", "q", close_panel, opts)
end

function M.open(opts)
	opts = opts or {}
	ui.ensure_highlights()
	delete_named_buffer("nvime://chat-input")
	sync_active_panel_to_session()

	local session = opts.session_id and get_session(opts.session_id) or active_session()
	if not session then
		session = create_session()
	end
	session.provider = opts.provider or session.provider or (state.config and state.config.provider) or "claude"
	touch_session(session)
	state.chat.active_session_id = session.id
	sync_session_to_legacy(session)

	local panel = state.panels.chat or {}
	local was_open = panel.winid and vim.api.nvim_win_is_valid(panel.winid)
	if panel.input_winid and panel.input_winid ~= panel.winid and vim.api.nvim_win_is_valid(panel.input_winid) then
		pcall(vim.api.nvim_win_close, panel.input_winid, true)
	end
	local scroll_buf = ensure_session_buffer(session)

	local scroll_win =
		open_or_configure_window(scroll_buf, panel.winid, scroll_config(), configure_scrollback_window, true)

	state.panels.chat = {
		bufnr = scroll_buf,
		winid = scroll_win,
		input_bufnr = scroll_buf,
		input_winid = scroll_win,
		input_start = session.input_start,
		input_active = session.input_active == true,
		session_id = session.id,
	}

	attach_panel(scroll_buf)
	attach_focus_lock(scroll_buf)
	attach_input_guard(scroll_buf)
	refresh_header(scroll_buf)
	reset_input(current_input_text(), { force_follow = not was_open })
	if not state.panels.chat.input_active then
		set_locked(scroll_buf, true)
	end
	decorate_scrollback(scroll_buf)
	decorate_input(scroll_buf)

	if opts.focus_input then
		M.prompt()
	end

	return scroll_buf
end

function M.refresh(bufnr)
	local panel = state.panels.chat
	if not panel then
		return
	end
	bufnr = bufnr or panel.bufnr
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
			vim.api.nvim_win_set_config(panel.winid, scroll_config())
			configure_scrollback_window(panel.winid)
		end
		refresh_header(bufnr)
		if not panel.input_active then
			set_locked(bufnr, true)
		end
	end
	refresh_input()
	sync_active_panel_to_session()
end

local spinner_timer = nil

local function stop_spinner_timer()
	if spinner_timer then
		spinner_timer:stop()
		spinner_timer:close()
		spinner_timer = nil
	end
end

local function refresh_input_indicator()
	local panel = state.panels.chat
	if not panel or not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
		return
	end
	decorate_input(panel.bufnr)
end

local function ensure_spinner_timer()
	if spinner_timer then
		return
	end
	local uv = vim.uv or vim.loop
	if not uv or not uv.new_timer then
		return
	end
	spinner_timer = uv.new_timer()
	spinner_timer:start(120, 120, function()
		vim.schedule(function()
			local session = active_session()
			local panel = state.panels.chat
			local open = panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid)
			if not session or not session.busy or not open then
				stop_spinner_timer()
				refresh_input_indicator()
				return
			end
			refresh_input_indicator()
		end)
	end)
end

local function append_scrollback(text, session_id)
	if not text or text == "" then
		return
	end
	if vim.in_fast_event and vim.in_fast_event() then
		vim.schedule(function()
			append_scrollback(text, session_id)
		end)
		return
	end

	local session = session_id and get_session(session_id) or ensure_active_session()
	local bufnr = ensure_session_buffer(session)
	if not bufnr then
		return
	end

	vim.schedule(function()
		local panel = panel_for_session(session)
		if not vim.api.nvim_buf_is_valid(bufnr) then
			return
		end
		local follow = should_auto_scroll(panel)
		local view = follow and nil or save_window_view(panel.winid)
		with_writable(bufnr, function()
			local parts = vim.split(text, "\n", { plain = true })
			local input_start = panel.input_start or (line_count(bufnr) + 1)
			local target = math.max(0, input_start - 2)
			local current = vim.api.nvim_buf_get_lines(bufnr, target, target + 1, false)[1] or ""
			vim.api.nvim_buf_set_lines(bufnr, target, target + 1, false, { current .. parts[1] })
			if #parts > 1 then
				local rest = {}
				for i = 2, #parts do
					rest[#rest + 1] = parts[i]
				end
				vim.api.nvim_buf_set_lines(bufnr, target + 1, target + 1, false, rest)
				panel.input_start = input_start + #rest
				session.input_start = panel.input_start
			end
			touch_session(session)
		end, decorate_scrollback, panel)
		if not panel.input_active then
			set_locked(bufnr, true)
		end
		local active_panel = state.panels.chat
		if
			state.chat
			and state.chat.active_session_id == session.id
			and active_panel
			and active_panel.session_id == session.id
		then
			active_panel.input_start = session.input_start
			sync_session_to_legacy(session)
			if follow then
				scroll_to_bottom()
			else
				restore_window_view(panel.winid, view)
			end
		end
	end)
end

local function append_user_message(bufnr, text, session)
	local panel = panel_for_session(session)
	with_writable(bufnr, function()
		local insert_at = math.max(0, (panel.input_start or (line_count(bufnr) + 1)) - 1)
		local lines = {
			"",
			prompt_prefix() .. text,
		}
		vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, lines)
		panel.input_start = insert_at + #lines + 1
		if session then
			session.input_start = panel.input_start
			touch_session(session)
		end
	end, decorate_scrollback, panel)
	if not panel.input_active then
		set_locked(bufnr, true)
	end
	if session and state.chat.active_session_id == session.id then
		state.panels.chat.input_start = session.input_start
		scroll_to_bottom()
	end
end

local function append_response_header(bufnr, session)
	local panel = panel_for_session(session)
	with_writable(bufnr, function()
		local insert_at = math.max(0, (panel.input_start or (line_count(bufnr) + 1)) - 1)
		local lines = {
			"",
			"[" .. provider() .. " response]",
			"",
		}
		vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, lines)
		panel.input_start = insert_at + #lines + 1
		if session then
			session.input_start = panel.input_start
			touch_session(session)
		end
	end, decorate_scrollback, panel)
	if not panel.input_active then
		set_locked(bufnr, true)
	end
	if session and state.chat.active_session_id == session.id then
		state.panels.chat.input_start = session.input_start
		scroll_to_bottom()
	end
end

local function trim_history(session)
	session = session or ensure_active_session()
	local max = chat_config().max_history_messages or 24
	session.history = session.history or {}
	while #session.history > max do
		table.remove(session.history, 1)
	end
	sync_session_to_legacy(session)
end

local function mark_provider_session(session, provider_name, provider_session_id)
	if not provider_session_id or provider_session_id == "" then
		return
	end
	session = session or ensure_active_session()
	session.provider_sessions = session.provider_sessions or {}
	session.provider_sessions[provider_name] = provider_session_id
	touch_session(session)
end

function M.agent_run_opts(provider_name, session_id)
	provider_name = provider_name or provider()
	local session = session_id and get_session(session_id) or ensure_active_session()
	session.provider_sessions = session.provider_sessions or {}
	session.provider_workspaces = session.provider_workspaces or {}
	if not session.provider_workspaces[provider_name] then
		session.provider_workspaces[provider_name] = vim.fn.tempname() .. "/workspace"
	end
	local resume_id = session.provider_sessions[provider_name]
	touch_session(session)
	return {
		persist_session = true,
		resume_session_id = resume_id,
		markdown_workspace = session.provider_workspaces[provider_name],
		on_session_id = function(provider_session_id)
			mark_provider_session(session, provider_name, provider_session_id)
		end,
	}
end

local function append_transcript(lines, session)
	session = session or ensure_active_session()
	lines[#lines + 1] = "Conversation so far:"
	if #(session.history or {}) == 0 then
		lines[#lines + 1] = "(empty)"
	else
		for _, message in ipairs(session.history or {}) do
			lines[#lines + 1] = string.upper(message.role) .. ": " .. message.content
		end
	end
end

local function build_conversation_prompt(text, opts)
	opts = opts or {}
	local session = opts.session or ensure_active_session()
	local markdown_policy = "Markdown writes are disabled in this lane."
	if ((state.config or {}).review or {}).allow_markdown_writes == true then
		markdown_policy =
			"You may create or update Markdown documentation files only (*.md, *.markdown). Do not edit source/config files directly."
	end
	local shell_policy = "Shell commands are disabled."
	if ((state.config or {}).review or {}).allow_shell == true then
		shell_policy = "You may run shell commands, including curl, for inspection, external docs, and tests."
	end
	local web_policy = "Native web fetch/search tools are disabled."
	if ((state.config or {}).review or {}).allow_web ~= false then
		web_policy = "You may use web fetch/search tools for external documentation and current information."
	end

	local lines = {
		"NVIME CHAT MODE.",
		"You are the side agent inside Neovim.",
		"You may answer questions, review code, and suggest changes.",
		markdown_policy,
		shell_policy,
		web_policy,
		"Never edit non-Markdown files from this lane. Source changes must go through NVIME EDIT MODE and reviewed diffs.",
	}

	if opts.resume_session_id then
		lines[#lines + 1] =
			"You are continuing this provider's native conversation via resume. Use that native context for prior turns."
	else
		lines[#lines + 1] = "Continue the conversation using the transcript below."
	end

	lines[#lines + 1] = ""
	if not opts.resume_session_id or opts.include_transcript then
		append_transcript(lines, session)
	elseif opts.native_context_only then
		lines[#lines + 1] = "Conversation so far: available from the resumed native provider session."
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "USER: " .. text
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Answer the latest user message with the prior conversation in mind."
	return table.concat(lines, "\n")
end

function M.set_busy(value, session_id)
	if vim.in_fast_event and vim.in_fast_event() then
		vim.schedule(function()
			M.set_busy(value, session_id)
		end)
		return
	end
	local session = session_id and get_session(session_id) or ensure_active_session()
	session.busy = value == true
	if not session.busy then
		session.progress = nil
	else
		ensure_spinner_timer()
	end
	touch_session(session)
	if state.chat.active_session_id == session.id then
		refresh_input_indicator()
	end
	spinner.update()
end

function M.set_progress(text, session_id)
	if vim.in_fast_event and vim.in_fast_event() then
		vim.schedule(function()
			M.set_progress(text, session_id)
		end)
		return
	end
	local compact = progress.compact(text)
	if compact == "" then
		return
	end
	local session = session_id and get_session(session_id) or ensure_active_session()
	session.progress = compact
	touch_session(session)
	if state.chat.active_session_id == session.id then
		refresh_input_indicator()
	end
	spinner.update()
end

function M.append(text, session_id)
	if vim.in_fast_event and vim.in_fast_event() then
		vim.schedule(function()
			M.append(text, session_id)
		end)
		return
	end
	local session = session_id and get_session(session_id) or ensure_active_session()
	append_scrollback(text, session.id)
end

function M.append_user(text, session_id)
	if vim.in_fast_event and vim.in_fast_event() then
		vim.schedule(function()
			M.append_user(text, session_id)
		end)
		return
	end
	local session = session_id and get_session(session_id) or ensure_active_session()
	local bufnr = M.open({ session_id = session.id })
	append_user_message(bufnr, text, session)
end

function M.append_response_header(session_id)
	if vim.in_fast_event and vim.in_fast_event() then
		vim.schedule(function()
			M.append_response_header(session_id)
		end)
		return
	end
	local session = session_id and get_session(session_id) or ensure_active_session()
	local bufnr = M.open({ session_id = session.id })
	append_response_header(bufnr, session)
end

function M.submit(text, opts)
	opts = opts or {}
	local session = opts.session_id and get_session(opts.session_id) or ensure_active_session()
	state.chat.active_session_id = session.id
	sync_session_to_legacy(session)
	local bufnr = M.open({ session_id = session.id })
	text = vim.trim(text or "")
	if text == "" then
		reset_input("")
		return
	end

	session.busy = true
	session.progress = nil
	touch_session(session)
	ensure_spinner_timer()
	M.refresh(bufnr)
	spinner.update()

	if opts.display_user ~= false then
		append_user_message(bufnr, text, session)
	end
	append_response_header(bufnr, session)

	session.history = session.history or {}
	session.history[#session.history + 1] = {
		role = "user",
		content = text,
	}
	if not session.title or session.title:match("^Chat #%d+$") then
		session.title = summarize_title(text) or session.title
	end
	trim_history(session)

	local provider_name = provider()
	session.provider = provider_name

	local agent_session = M.agent_run_opts(provider_name, session.id)
	local include_transcript = not agent_session.resume_session_id or session.last_provider ~= provider_name
	local prompt = build_conversation_prompt(text, {
		session = session,
		resume_session_id = agent_session.resume_session_id,
		include_transcript = include_transcript,
		native_context_only = true,
	})
	local response = {}
	agents.run({
		provider = provider_name,
		lane = "review",
		prompt = prompt,
		persist_session = agent_session.persist_session,
		resume_session_id = agent_session.resume_session_id,
		markdown_workspace = agent_session.markdown_workspace,
		on_session_id = agent_session.on_session_id,
		on_text = function(chunk)
			response[#response + 1] = chunk
			append_scrollback(chunk, session.id)
		end,
		on_progress = function(chunk)
			M.set_progress(chunk, session.id)
		end,
		on_exit = function(result)
			local assistant_text = vim.trim(table.concat(response))
			if assistant_text ~= "" then
				session.history = session.history or {}
				session.history[#session.history + 1] = {
					role = "assistant",
					content = assistant_text,
				}
				trim_history(session)
			end
			session.last_provider = provider_name
			session.busy = false
			session.progress = nil
			touch_session(session)
			spinner.update()
			local synced = result.nvime_synced_markdown or {}
			if #synced > 0 then
				vim.notify("nvime synced markdown: " .. table.concat(synced, ", "), vim.log.levels.INFO)
			end
			if result.code ~= 0 then
				append_scrollback("\n[nvime] chat failed with code " .. tostring(result.code) .. "\n", session.id)
			end
			notify_finished(session, result.code)
			vim.schedule(function()
				refresh_input_indicator()
				if state.chat.active_session_id == session.id and panel_is_open(session.id) then
					M.refresh(bufnr)
				end
			end)
		end,
	})
end

function M.insert_prompt(text)
	text = vim.trim(text or "")
	M.open()
	reset_input(text, { force_follow = true })
	M.prompt({ cursor = "end" })
end

function M.choose_prompt()
	prompts.choose("general", function(text)
		M.insert_prompt(text)
	end)
end

function M.prompt(opts)
	opts = opts or {}
	M.open()
	local panel = state.panels.chat
	if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
		return
	end
	panel.input_active = true
	set_locked(panel.input_bufnr, false)
	vim.api.nvim_set_current_win(panel.winid)
	local prompt_lnum = panel.input_start or 1
	local prefix_col = #prompt_prefix()
	local end_col = prompt_end_col(panel)
	if opts.preserve_cursor then
		local cur_ok, cursor = pcall(vim.api.nvim_win_get_cursor, panel.winid)
		if cur_ok and cursor[1] == prompt_lnum and cursor[2] >= prefix_col then
			pcall(vim.cmd, "startinsert")
			return
		end
	end
	local append = opts.cursor == "end"
	local empty_prompt = end_col <= prefix_col
	local col = (append or empty_prompt) and math.max(0, end_col - 1) or prefix_col
	pcall(vim.api.nvim_win_set_cursor, panel.winid, { prompt_lnum, col })
	pcall(vim.fn.winrestview, { topline = math.max(1, prompt_lnum - vim.api.nvim_win_get_height(panel.winid) + 2) })
	pcall(vim.cmd, (append or empty_prompt) and "startinsert!" or "startinsert")
end

function M.submit_current()
	local panel = state.panels.chat
	if not panel or not panel.input_bufnr or not vim.api.nvim_buf_is_valid(panel.input_bufnr) then
		M.prompt()
		return
	end

	local prompt_lnum = panel.input_start or 1
	local line = vim.api.nvim_buf_get_lines(panel.input_bufnr, prompt_lnum - 1, prompt_lnum, false)[1] or ""
	local text = extract_prompt_text(line)
	reset_input("")
	if text == "" then
		M.prompt()
		return
	end
	M.submit(text)
end

function M.active_session_id()
	return state.chat and state.chat.active_session_id
end

function M.is_open(session_id)
	return panel_is_open(session_id)
end

function M.get_session(id)
	return get_session(id)
end

function M.winbar_text()
	ui.ensure_highlights()
	local session = active_session()
	local provider_name = provider()
	local provider_hl = provider_name == "claude" and "NvimeProviderClaude" or "NvimeProviderCodex"
	local busy = session and session.busy
	local status_hl = busy and "NvimeStatusRunning" or "NvimeStatusIdle"
	local status_text = busy and (render.spinner_text() .. " running") or (ui.icon("idle") .. " idle")
	local lane = "review/docs"

	local nvime_label = " nvime.nvim "
	local version_label = " v0.2.0 "
	local sep = "  "
	local visible = nvime_label .. sep .. version_label .. sep .. provider_name .. sep .. lane .. sep .. status_text
	local visible_width = vim.fn.strdisplaywidth(visible)

	local panel = state.panels.chat
	local win_width = vim.o.columns
	if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
		win_width = vim.api.nvim_win_get_width(panel.winid)
	end
	local pad = math.max(0, math.floor((win_width - visible_width) / 2))

	return string.rep(" ", pad)
		.. "%#NvimeHeaderBlock#"
		.. nvime_label
		.. "%*"
		.. sep
		.. "%#NvimeHeaderBlockSecondary#"
		.. version_label
		.. "%*"
		.. sep
		.. "%#"
		.. provider_hl
		.. "#"
		.. provider_name
		.. "%*"
		.. sep
		.. "%#NvimeMuted#"
		.. lane
		.. "%*"
		.. sep
		.. "%#"
		.. status_hl
		.. "#"
		.. status_text
		.. "%*"
end

function M.sessions()
	local items = vim.deepcopy(ensure_sessions())
	table.sort(items, function(left, right)
		if (left.updated_at or 0) == (right.updated_at or 0) then
			return (left.id or 0) > (right.id or 0)
		end
		return (left.updated_at or 0) > (right.updated_at or 0)
	end)
	return items
end

function M.session_count()
	return #ensure_sessions()
end

function M.new_session(opts)
	opts = opts or {}
	sync_active_panel_to_session()
	local session = create_session({
		provider = opts.provider,
		title = opts.title,
	})
	return M.open({
		session_id = session.id,
		focus_input = opts.focus_input == true,
	})
end

function M.open_session(id, opts)
	opts = opts or {}
	local session = get_session(id)
	if not session then
		vim.notify("nvime chat no longer exists", vim.log.levels.WARN)
		return nil
	end
	state.chat.active_session_id = session.id
	sync_session_to_legacy(session)
	return M.open({
		session_id = session.id,
		focus_input = opts.focus_input == true,
	})
end

function M.rename_session(id, title)
	local session = get_session(id)
	if not session then
		return false
	end
	title = vim.trim(title or "")
	if title == "" then
		return false
	end
	session.title = title
	touch_session(session)
	save_sessions_now()
	return true
end

function M.delete_sessions(ids)
	if not ids or #ids == 0 then
		return 0
	end
	local remove = {}
	for _, id in ipairs(ids) do
		remove[tonumber(id)] = true
	end

	local kept = {}
	local deleted = 0
	for _, session in ipairs(ensure_sessions()) do
		if remove[tonumber(session.id)] then
			deleted = deleted + 1
			if session.bufnr and vim.api.nvim_buf_is_valid(session.bufnr) then
				pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
			else
				delete_named_buffer(session_buffer_name(session))
			end
			if state.chat.active_session_id == session.id then
				state.chat.active_session_id = nil
				local panel = state.panels.chat
				if
					panel
					and panel.session_id == session.id
					and panel.winid
					and vim.api.nvim_win_is_valid(panel.winid)
				then
					pcall(vim.api.nvim_win_close, panel.winid, true)
				end
				state.panels.chat = nil
			end
			if state.last_session and state.last_session.kind == "chat" and state.last_session.id == session.id then
				state.last_session = nil
			end
		else
			kept[#kept + 1] = session
		end
	end
	state.chat.sessions = kept
	if not state.chat.active_session_id then
		local next_session = state.chat.sessions[1]
		if next_session then
			state.chat.active_session_id = next_session.id
			sync_session_to_legacy(next_session)
		else
			sync_session_to_legacy({
				history = {},
				provider_sessions = {},
				provider_workspaces = {},
			})
		end
	end
	if deleted > 0 then
		save_sessions_now()
	end
	return deleted
end

function M.save_sessions()
	save_pending = false
	save_sessions_now()
end

function M.reload_sessions()
	sessions_loaded = false
	state.chat.sessions = {}
	state.chat.next_session_id = 1
	state.chat.active_session_id = nil
	state.chat.history = {}
	state.chat.provider_sessions = {}
	state.chat.provider_workspaces = {}
	state.chat.last_provider = nil
	state.chat._legacy_session_id = nil
	load_sessions()
	return state.chat.sessions
end

function M.sessions_path()
	return sessions_path()
end

return M
