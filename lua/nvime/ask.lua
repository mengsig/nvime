local agents = require("nvime.agents")
local selection_state = require("nvime.selection")
local state = require("nvime.state")
local ts = require("nvime.treesitter")

local M = {}

local function current_path(bufnr)
	local name = vim.api.nvim_buf_get_name(bufnr)
	if name == "" or vim.fn.filereadable(name) ~= 1 then
		return nil
	end
	local abs = vim.fn.fnamemodify(name, ":p")
	local root = vim.fn.systemlist({ "git", "-C", vim.fn.fnamemodify(name, ":h"), "rev-parse", "--show-toplevel" })[1]
	if root and root ~= "" then
		if vim.fs and vim.fs.relpath then
			local rel = vim.fs.relpath(root, abs)
			if rel then
				return rel
			end
		elseif abs:sub(1, #root + 1) == root .. "/" then
			return abs:sub(#root + 2)
		end
	end
	return abs
end

local function build_prompt(selection, question)
	local lines = ts.lines(selection)
	local body = table.concat(lines, "\n")
	local max_run = 2
	for run in body:gmatch("`+") do
		if #run > max_run then
			max_run = #run
		end
	end
	local fence = string.rep("`", max_run + 1)
	return table.concat({
		"NVIME READ-ONLY SELECTION CHAT.",
		"You are the read-only side agent inside Neovim.",
		"Answer the user's question about the selected code. Do not edit files. Do not produce a patch unless only explaining what a future patch would do.",
		"",
		"File: " .. selection.path,
		"Selected range: " .. selection.line1 .. "-" .. selection.line2 .. " (" .. selection.source .. ")",
		"Question: " .. question,
		"",
		"Selected code:",
		fence,
		body,
		fence,
	}, "\n")
end

local EDIT_KEYWORDS = {
	"proceed",
	"go ahead",
	"fix",
	"change",
	"update",
	"apply",
	"implement",
	"refactor",
	"rename",
	"convert",
	"replace",
	"remove",
	"add",
	"patch",
	"make it",
}

local NEGATION_PATTERNS = {
	"don'?t",
	"do not",
	"doesn'?t",
	"does not",
	"shouldn'?t",
	"should not",
	"no need",
	"never",
}

local function has_word(text, phrase)
	if phrase:find(" ", 1, true) then
		return text:find(phrase, 1, true) ~= nil
	end
	return text:find("%f[%w]" .. phrase .. "%f[%W]") ~= nil
end

local function has_negation(text)
	for _, pattern in ipairs(NEGATION_PATTERNS) do
		if text:find(pattern) then
			return true
		end
	end
	return false
end

local function wants_edit_followup(input)
	local text = (input or ""):lower()
	if text == "" then
		return false
	end
	if text:match("^%s*/edit%f[%W]") or text:match("^%s*/edit$") then
		return true
	end
	if text:match("^%s*what%s") or text:match("^%s*why%s") or text:match("^%s*how%s") then
		return false
	end
	if has_negation(text) then
		return false
	end
	for _, keyword in ipairs(EDIT_KEYWORDS) do
		if has_word(text, keyword) then
			return true
		end
	end
	return false
end

local run

local function arm_followup(selection, provider, session_id, open_panel)
	selection_state.prompt({
		provider = provider,
		mode = "ask",
		selection = selection,
		session_id = session_id,
		focus_input = false,
		open = open_panel ~= false,
		on_submit = function(input, selected_provider)
			selected_provider = selected_provider or provider
			if wants_edit_followup(input) then
				require("nvime.edit").start({
					selection = selection,
					provider = selected_provider,
					intent = input,
					session_id = session_id,
				})
			else
				run(selection, input, selected_provider, { session_id = session_id })
			end
		end,
	})
end

run = function(selection, question, provider, session_opts)
	session_opts = session_opts or {}
	selection_state.open({
		provider = provider,
		mode = "ask",
		selection = selection,
		session_id = session_opts.session_id,
		new_session = session_opts.new_session,
	})
	local session_id = selection_state.active_session_id()
	selection_state.append_user(provider, "ask", question, session_id)
	selection_state.append_response_header(provider, "ask", session_id)

	local response = {}
	local agent_session = selection_state.agent_run_opts(session_id, provider)
	selection_state.set_busy(true, session_id)
	agents.run({
		provider = provider,
		lane = "ask",
		prompt = build_prompt(selection, question),
		persist_session = agent_session.persist_session,
		resume_session_id = agent_session.resume_session_id,
		on_session_id = agent_session.on_session_id,
		on_text = function(text)
			response[#response + 1] = text
			selection_state.append(text, session_id)
		end,
		on_progress = function(text)
			selection_state.append(text, session_id)
		end,
		on_exit = function(result)
			selection_state.set_busy(false, session_id)
			selection_state.mark_last_ask(session_id, {
				selection = selection_state.snapshot(selection),
				provider = provider,
				question = question,
				answer = vim.trim(table.concat(response)),
			})
			if result.code ~= 0 then
				selection_state.append("\n[nvime] ask failed with code " .. tostring(result.code) .. "\n", session_id)
			end
			arm_followup(selection, provider, session_id, selection_state.active_session_id() == session_id)
		end,
	})
end

function M.start(opts)
	opts = opts or {}
	local selection, err
	if opts.selection then
		selection = opts.selection
	else
		selection, err = ts.range_from_command(opts)
	end
	if not selection then
		vim.notify(
			err or "nvime ask needs a visual range or a Tree-sitter function at the cursor",
			vim.log.levels.ERROR
		)
		return
	end

	selection.path = selection.path or current_path(selection.bufnr)
	if not selection.path then
		vim.notify("nvime ask requires a named file buffer", vim.log.levels.ERROR)
		return
	end

	local provider = opts.provider or require("nvime.state").config.provider
	local question = opts.question or opts.prompt
	local function proceed(session_opts)
		session_opts = session_opts or {}
		if not question or question == "" then
			selection_state.prompt({
				provider = provider,
				mode = "ask",
				selection = selection,
				session_id = session_opts.session_id,
				new_session = session_opts.new_session,
				on_submit = function(input, selected_provider)
					run(selection, input, selected_provider or provider, { session_id = selection_state.active_session_id() })
				end,
			})
			return
		end

		run(selection, question, provider, session_opts)
	end

	if opts.choose_session then
		selection_state.choose_session(selection, {
			mode = "ask",
			provider = provider,
		}, proceed)
		return
	end

	if not question or question == "" then
		selection_state.prompt({
			provider = provider,
			mode = "ask",
			selection = selection,
			session_id = opts.session_id,
			new_session = opts.new_session,
			on_submit = function(input, selected_provider)
				run(selection, input, selected_provider or provider, { session_id = selection_state.active_session_id() })
			end,
		})
		return
	end

	run(selection, question, provider, { session_id = opts.session_id, new_session = opts.new_session })
end

return M
