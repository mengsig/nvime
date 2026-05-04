local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local fake_claude = root .. "/tests/fixtures/claude"
local audit_path = tmp .. "/audit.jsonl"

require("nvime").setup({
  provider = "claude",
  providers = {
    claude = {
      cmd = fake_claude,
    },
    codex = {
      cmd = fake_claude,
    },
  },
  audit = {
    path = audit_path,
    log_prompts = true,
  },
  guard = {
    notify = false,
    block_cmdline = false,
  },
})

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error((label or "assert_eq") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
end

assert(vim.fn.maparg("<leader>nr", "n") ~= "", "default review keymap exists")
assert(vim.fn.maparg("<leader>ne", "x") ~= "", "default visual edit keymap exists")
assert(vim.fn.maparg("<leader>nq", "x") ~= "", "default visual ask keymap exists")
assert(vim.fn.maparg("<leader>ne", "n") == "<Cmd>NvimeChats edit<CR>", "default normal edit keymap opens edit picker")
assert(vim.fn.maparg("<leader>nq", "n") == "<Cmd>NvimeChats ask<CR>", "default normal ask keymap opens ask picker")
assert(vim.fn.maparg("<leader>np", "n") ~= "", "default provider keymap exists")

vim.cmd("NvimeProvider codex")
assert(require("nvime.state").config.provider == "codex", "provider command sets codex")
vim.cmd("NvimeProvider claude")
assert(require("nvime.state").config.provider == "claude", "provider command sets claude")

local stale_chat = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(stale_chat, "nvime://stale-chat")
local chat = require("nvime.ui").panel("stale-chat", "nvime", "nvime")
assert(chat == stale_chat, "reuses pre-existing nvime named buffer")

local stale_chat_input = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(stale_chat_input, "nvime://chat-input")
local chat_buf = require("nvime.chat").open()
local chat_panel = require("nvime.state").panels.chat
local chat_win = chat_panel.winid
local chat_input = chat_panel.input_bufnr
local chat_input_win = chat_panel.input_winid
assert(vim.api.nvim_win_get_config(chat_win).relative == "editor", "chat opens as a float by default")
assert(chat_input_win == chat_win, "chat uses one floating window")
assert(chat_input == chat_buf, "chat input shares the scrollback buffer")
assert(not vim.api.nvim_buf_is_valid(stale_chat_input), "chat removes legacy input buffers")
assert(vim.api.nvim_win_get_height(chat_win) >= 16, "chat has a usable float height")
local chat_lines = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(not chat_lines:find("====", 1, true), "chat does not write rule text into the transcript")
assert(vim.bo[chat_buf].modifiable == false, "chat buffer is locked until the input is focused")
local input_lines = table.concat(vim.api.nvim_buf_get_lines(chat_buf, chat_panel.input_start - 1, -1, false), "\n")
assert(input_lines:find("[claude]$ ", 1, true), "chat input has a terminal prompt")
assert(#vim.api.nvim_buf_get_extmarks(chat_buf, vim.api.nvim_create_namespace("nvime.chat"), 0, -1, {}) > 0, "chat has decorations")
assert(#vim.api.nvim_buf_get_extmarks(chat_input, vim.api.nvim_create_namespace("nvime.chat.input"), 0, -1, {}) > 0, "chat input has decorations")

require("nvime.chat").prompt()
assert(vim.api.nvim_get_current_buf() == chat_buf, "chat prompt focuses shared input buffer")
assert(vim.api.nvim_get_current_win() == chat_input_win, "chat prompt focuses the single chat window")
assert(vim.bo[chat_buf].modifiable == true, "chat buffer becomes editable while typing on the prompt")
vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, { "oops" })
assert(vim.wait(1000, function()
  local guarded = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  return guarded:find("oops", 1, true) == nil and guarded:find("[claude]$ ", 1, true) ~= nil
end, 20), "chat guard restores edits outside the prompt line")
local append_prompt_line = "[claude]$ Hey, please iterate throughout"
vim.api.nvim_buf_set_lines(chat_buf, chat_panel.input_start - 1, chat_panel.input_start, false, { append_prompt_line })
pcall(vim.cmd.stopinsert)
vim.api.nvim_win_set_cursor(chat_win, { chat_panel.input_start, #"[claude]$ " })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  return vim.api.nvim_win_get_cursor(chat_win)[2] >= (#append_prompt_line - 2)
end, 20), "chat A appends at the end of the live prompt line")
pcall(vim.cmd.stopinsert)
vim.api.nvim_buf_set_lines(chat_buf, chat_panel.input_start - 1, chat_panel.input_start, false, { "[claude]$ " })
vim.api.nvim_win_set_cursor(chat_win, { chat_panel.input_start, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Ityped<Esc>", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local line = vim.api.nvim_buf_get_lines(chat_buf, chat_panel.input_start - 1, chat_panel.input_start, false)[1] or ""
  return line == "[claude]$ typed"
end, 20), "chat I inserts after the prompt prefix on an empty prompt")
pcall(vim.cmd.stopinsert)

require("nvime.provider").cycle()
local cycled_lines = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
local cycled_input = table.concat(vim.api.nvim_buf_get_lines(chat_input, chat_panel.input_start - 1, -1, false), "\n")
assert(require("nvime.state").config.provider == "codex", "provider cycles in chat")
assert(not cycled_lines:find("====", 1, true), "provider cycle keeps transcript free of rule text")
assert(cycled_input:find("[codex]$ ", 1, true), "provider cycle updates input prompt")
vim.cmd("NvimeProvider claude")

require("nvime.chat").submit("say hello")
local chat_done = vim.wait(5000, function()
  return #require("nvime.state").chat.history >= 2
end, 20)
assert(chat_done, "chat prompt submits to provider")
local chat_transcript = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(not chat_transcript:find("chat exited", 1, true), "chat transcript omits successful exit status")
local saw_code_fence = false
local saw_code_line = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat_buf, vim.api.nvim_create_namespace("nvime.chat"), 0, -1, {
  details = true,
})) do
  local details = mark[4] or {}
  saw_code_fence = saw_code_fence or details.hl_group == "NvimeCodeFence"
  saw_code_line = saw_code_line or details.hl_group == "NvimeCode"
end
assert(saw_code_fence and saw_code_line, "chat parses and highlights fenced code output")
assert(#require("nvime.state").chat.history >= 2, "chat keeps transcript history")

require("nvime.chat").submit("what did I just say?")
local followup_done = vim.wait(5000, function()
  return #require("nvime.state").chat.history >= 4
end, 20)
assert(followup_done, "chat follow-up updates transcript history")
assert(#require("nvime.state").chat.history >= 4, "chat history is retained for reopened chat prompts")

local writer_claude = tmp .. "/writer-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' '# Generated by nvime test' > NVIME_TEST_DOC.md",
  "printf '%s\\n' 'source writes must not sync' > SHOULD_NOT_SYNC.lua",
  "printf '%s\\n' 'wrote markdown'",
}, writer_claude)
vim.fn.setfperm(writer_claude, "rwxr-xr-x")
local old_claude_cmd = require("nvime.state").config.providers.claude.cmd
require("nvime.state").config.providers.claude.cmd = writer_claude
local markdown_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "review",
  prompt = "create markdown docs",
  on_exit = function(result)
    markdown_done = result.code == 0
      and vim.fn.filereadable(root .. "/NVIME_TEST_DOC.md") == 1
      and vim.fn.filereadable(root .. "/SHOULD_NOT_SYNC.lua") == 0
      and #(result.nvime_synced_markdown or {}) == 1
  end,
})
assert(vim.wait(5000, function()
  return markdown_done
end, 20), "review lane syncs markdown writes only")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd
vim.fn.delete(root .. "/NVIME_TEST_DOC.md")

local native_claude_id = "11111111-1111-1111-1111-111111111111"
local fake_resume_claude = tmp .. "/fake-resume-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"" .. native_claude_id .. "\"}'",
  "printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"native claude ok\"}]}}'",
}, fake_resume_claude)
vim.fn.setfperm(fake_resume_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = fake_resume_claude
local native_claude_seen = nil
local native_claude_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "first native claude",
  persist_session = true,
  on_session_id = function(session_id)
    native_claude_seen = session_id
  end,
  on_exit = function(result)
    native_claude_done = result.code == 0
  end,
})
assert(vim.wait(5000, function()
  return native_claude_done
end, 20), "persistent claude selection lane runs")
assert_eq(native_claude_seen, native_claude_id, "claude session id is captured")
native_claude_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "second native claude",
  persist_session = true,
  resume_session_id = native_claude_seen,
  on_exit = function(result)
    native_claude_done = result.code == 0
  end,
})
assert(vim.wait(5000, function()
  return native_claude_done
end, 20), "claude resume lane runs")
local native_claude_audit = vim.fn.readfile(audit_path)
local first_native_claude = ""
local second_native_claude = ""
for _, line in ipairs(native_claude_audit) do
  if line:find("first native claude", 1, true) then
    first_native_claude = line
  elseif line:find("second native claude", 1, true) then
    second_native_claude = line
  end
end
assert(not first_native_claude:find("--no-session-persistence", 1, true), "persistent claude start keeps native session persistence")
assert(second_native_claude:find("--resume " .. native_claude_id, 1, true), "claude follow-up uses native resume")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

local noisy_lsp_claude = tmp .. "/noisy-lsp-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"LSP\",\"input\":{}}]}}'",
  "printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"LSP\",\"input\":{}}]}}'",
  "printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}'",
}, noisy_lsp_claude)
vim.fn.setfperm(noisy_lsp_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = noisy_lsp_claude
local lsp_progress = {}
local lsp_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "check lsp progress",
  persist_session = true,
  on_progress = function(text)
    lsp_progress[#lsp_progress + 1] = text
  end,
  on_exit = function(result)
    lsp_done = result.code == 0
  end,
})
assert(vim.wait(5000, function()
  return lsp_done
end, 20), "claude LSP progress fixture runs")
local lsp_progress_text = table.concat(lsp_progress)
local _, lsp_progress_count = lsp_progress_text:gsub("%[claude%] tool: LSP", "")
assert_eq(lsp_progress_count, 1, "duplicate Claude LSP progress is collapsed")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

local fake_codex = tmp .. "/fake-codex"
local native_codex_id = "22222222-2222-2222-2222-222222222222"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "test -d .git || { printf '%s\\n' 'missing temp git root'; exit 3; }",
  "cat >/dev/null",
  "printf '%s\\n' '{\"type\":\"turn.started\",\"session_id\":\"" .. native_codex_id .. "\"}'",
  "printf '%s\\n' '{\"item\":{\"type\":\"reasoning\",\"summary\":\"checking files\"}}'",
  "printf '%s\\n' '{\"item\":{\"type\":\"command_execution\",\"command\":\"rg README\"}}'",
  "printf '%s\\n' '{\"item\":{\"type\":\"agent_message\",\"text\":\"codex ok\"}}'",
}, fake_codex)
vim.fn.setfperm(fake_codex, "rwxr-xr-x")
require("nvime.state").config.providers.codex.cmd = fake_codex
local codex_done = false
local codex_text = {}
local codex_progress = {}
require("nvime.agents").run({
  provider = "codex",
  lane = "review",
  prompt = "check codex args",
  on_text = function(text)
    codex_text[#codex_text + 1] = text
  end,
  on_progress = function(text)
    codex_progress[#codex_progress + 1] = text
  end,
  on_exit = function(result)
    codex_done = result.code == 0
  end,
})
assert(vim.wait(5000, function()
  return codex_done
end, 20), "codex review lane runs with fake provider")
local codex_audit = table.concat(vim.fn.readfile(audit_path), "\n")
assert(codex_audit:find("%-%-skip%-git%-repo%-check"), "codex argv skips git repo check for nvime temp workspace")
assert(table.concat(codex_text):find("codex ok", 1, true), "codex final answer is delivered as text")
assert(not table.concat(codex_text):find("checking files", 1, true), "codex progress is not mixed into final text")
local codex_progress_text = table.concat(codex_progress)
assert(codex_progress_text:find("checking files", 1, true), "codex reasoning summaries stream as progress")
assert(codex_progress_text:find("rg README", 1, true), "codex tool activity streams as progress")

local codex_edit_done = false
require("nvime.agents").run({
  provider = "codex",
  lane = "edit",
  prompt = "check codex edit args",
  on_exit = function(result)
    codex_edit_done = result.code == 0
  end,
})
assert(vim.wait(5000, function()
  return codex_edit_done
end, 20), "codex edit lane runs with fake provider")
local codex_audit_after_edit = table.concat(vim.fn.readfile(audit_path), "\n")
assert(codex_audit_after_edit:find("check codex edit args", 1, true), "codex edit lane is audited")
assert(codex_audit_after_edit:find("%-%-skip%-git%-repo%-check"), "codex edit argv also skips git repo check")

local native_codex_seen = nil
local native_codex_done = false
require("nvime.agents").run({
  provider = "codex",
  lane = "ask",
  prompt = "first native codex",
  persist_session = true,
  on_session_id = function(session_id)
    native_codex_seen = session_id
  end,
  on_exit = function(result)
    native_codex_done = result.code == 0
  end,
})
assert(vim.wait(5000, function()
  return native_codex_done
end, 20), "persistent codex selection lane runs")
assert_eq(native_codex_seen, native_codex_id, "codex session id is captured")
native_codex_done = false
require("nvime.agents").run({
  provider = "codex",
  lane = "ask",
  prompt = "second native codex",
  persist_session = true,
  resume_session_id = native_codex_seen,
  on_exit = function(result)
    native_codex_done = result.code == 0
  end,
})
assert(vim.wait(5000, function()
  return native_codex_done
end, 20), "codex resume lane runs")
local native_codex_audit = vim.fn.readfile(audit_path)
local first_native_codex = ""
local second_native_codex = ""
for _, line in ipairs(native_codex_audit) do
  if line:find("first native codex", 1, true) then
    first_native_codex = line
  elseif line:find("second native codex", 1, true) then
    second_native_codex = line
  end
end
assert(not first_native_codex:find("--ephemeral", 1, true), "persistent codex start keeps native session persistence")
assert(second_native_codex:find("exec resume", 1, true), "codex follow-up uses exec resume")
assert(second_native_codex:find(native_codex_id, 1, true), "codex follow-up passes the native session id")

local stale_selection_input = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(stale_selection_input, "nvime://selection-input")
require("nvime.ask").start({
  provider = "claude",
  question = "does this look right?",
  selection = {
    bufnr = chat_buf,
    line1 = 1,
    line2 = 1,
    path = "nvime-chat.txt",
    source = "test",
  },
})
local ask_done = vim.wait(5000, function()
  local selection_buf = require("nvime.state").panels.selection and require("nvime.state").panels.selection.bufnr
  if not selection_buf then
    return false
  end
  local ask = require("nvime.state").selection.last_ask
  return ask and ask.selection.path == "nvime-chat.txt"
end, 20)
assert(ask_done, "read-only selection ask uses selection lane")
local ask_transcript = table.concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.selection.bufnr, 0, -1, false), "\n")
assert(not ask_transcript:find("ask exited", 1, true), "ask transcript omits successful exit status")
assert(not vim.api.nvim_buf_is_valid(stale_selection_input), "selection removes legacy input buffers")
assert(require("nvime.state").panels.selection.bufnr ~= chat_buf, "selection workflow has a separate buffer from general chat")
assert(require("nvime.state").panels.selection.input_bufnr ~= nil, "selection workflow has a prompt buffer")
assert(
  require("nvime.state").panels.selection.input_bufnr == require("nvime.state").panels.selection.bufnr,
  "selection input shares the workflow buffer"
)
assert(
  require("nvime.state").panels.selection.input_winid == require("nvime.state").panels.selection.winid,
  "selection uses one floating window"
)
assert(vim.bo[require("nvime.state").panels.selection.bufnr].modifiable == false, "selection workflow locks until input focus")
assert(require("nvime.selection").session_count() == 1, "selection ask creates one resumable discussion")
local selection_session_buf = require("nvime.state").panels.selection.bufnr
local selection_session_win = require("nvime.state").panels.selection.winid
if selection_session_win and vim.api.nvim_win_is_valid(selection_session_win) then
  pcall(vim.api.nvim_win_close, selection_session_win, true)
end
vim.cmd("NvimeChats ask")
local chats_panel = require("nvime.state").panels.chats
assert(chats_panel and vim.api.nvim_win_is_valid(chats_panel.winid), "NvimeChats opens a floating picker")
local chats_lines = table.concat(vim.api.nvim_buf_get_lines(chats_panel.bufnr, 0, -1, false), "\n")
assert(chats_lines:find("start new ask session", 1, true), "chats picker offers a new ask session")
assert(chats_lines:find("nvime%-chat%.txt:1%-1"), "chats picker shows selection file and range")
vim.api.nvim_win_set_cursor(chats_panel.winid, { 7, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local panel = require("nvime.state").panels.selection
  return panel
    and panel.bufnr == selection_session_buf
    and panel.winid
    and vim.api.nvim_win_is_valid(panel.winid)
end, 20), "picker <CR> reopens the selected discussion")
pcall(vim.cmd.stopinsert)
require("nvime.provider").cycle({ scope = "selection" })
local active_selection_session = require("nvime.selection").get_session(require("nvime.selection").active_session_id())
local selection_prompt_after_cycle = table.concat(
  vim.api.nvim_buf_get_lines(
    require("nvime.state").panels.selection.bufnr,
    require("nvime.state").panels.selection.input_start - 1,
    -1,
    false
  ),
  "\n"
)
assert(active_selection_session.provider == "codex", "selection provider cycle updates the active discussion")
assert(selection_prompt_after_cycle:find("[codex ask]$ ", 1, true), "selection provider cycle updates the prompt")
require("nvime.provider").cycle({ scope = "selection" })
assert(active_selection_session.provider == "claude", "selection provider cycle can switch back")

local blocked_job = vim.fn.jobstart({ fake_claude, "-p", "should be blocked" })
assert_eq(blocked_job, -1, "direct jobstart block")

local blocked_system = vim.system({ fake_claude, "-p", "should be blocked" }):wait()
assert_eq(blocked_system.code, 126, "direct vim.system block")

vim.cmd.edit(tmp .. "/sample.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local function add(a,b)",
  "  return a-b",
  "end",
})

local target = vim.api.nvim_get_current_buf()
require("nvime.state").current_diff = nil
require("nvime.edit").start({
  provider = "claude",
  intent = "does this look right?",
  selection = {
    bufnr = target,
    line1 = 1,
    line2 = 3,
    path = "sample.lua",
    source = "test",
  },
})
local edit_question_done = vim.wait(5000, function()
  local ask = require("nvime.state").selection.last_ask
  return ask
    and ask.selection.path == "sample.lua"
    and tonumber(ask.selection.line1) == 1
    and tonumber(ask.selection.line2) == 3
end, 20)
assert(edit_question_done, "question-shaped edit routes to ask lane")
local edit_question_transcript = table.concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.selection.bufnr, 0, -1, false), "\n")
assert(not edit_question_transcript:find("ask exited", 1, true), "question-shaped edit omits successful ask exit status")
assert(require("nvime.state").current_diff == nil, "question-shaped edit does not open a diff")

assert(require("nvime.state").selection.last_ask ~= nil, "ask result is retained for edit handoff")
local selection_panel = require("nvime.state").panels.selection
assert(require("nvime.state").selection.pending_input.mode == "ask", "ask arms a follow-up prompt for the same selection")
require("nvime.selection").focus_input()
assert(vim.api.nvim_get_current_win() == selection_panel.input_winid, "ask follow-up focuses the selection prompt")
assert(vim.bo[selection_panel.bufnr].modifiable == true, "selection buffer becomes editable while typing on the prompt")
vim.api.nvim_buf_set_lines(selection_panel.bufnr, 0, 1, false, { "oops" })
assert(vim.wait(1000, function()
  local guarded = table.concat(vim.api.nvim_buf_get_lines(selection_panel.bufnr, 0, -1, false), "\n")
  return guarded:find("oops", 1, true) == nil and guarded:find("[claude ask]$ ", 1, true) ~= nil
end, 20), "selection guard restores edits outside the prompt line")
local edit_prompt_lnum = selection_panel.input_start
local edit_prompt_line = vim.api.nvim_buf_get_lines(selection_panel.bufnr, edit_prompt_lnum - 1, edit_prompt_lnum, false)[1] or ""
assert(edit_prompt_line:find("[claude ask]$ ", 1, true), "ask follow-up input shows the ask prompt")
vim.api.nvim_buf_set_lines(selection_panel.bufnr, edit_prompt_lnum - 1, edit_prompt_lnum, false, {
  "[claude ask]$ ",
})
vim.api.nvim_win_set_cursor(selection_panel.input_winid, { edit_prompt_lnum, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Ityped<Esc>", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local line = vim.api.nvim_buf_get_lines(selection_panel.bufnr, edit_prompt_lnum - 1, edit_prompt_lnum, false)[1] or ""
  return line == "[claude ask]$ typed"
end, 20), "selection I inserts after the prompt prefix on an empty prompt")
pcall(vim.cmd.stopinsert)
vim.api.nvim_buf_set_lines(selection_panel.bufnr, edit_prompt_lnum - 1, edit_prompt_lnum, false, {
  "[claude ask]$ please proceed with fixing this",
})
pcall(vim.cmd.stopinsert)
require("nvime.selection").submit_current()

local ready = vim.wait(5000, function()
  return require("nvime.state").current_diff ~= nil
end, 20)
assert(ready, "timed out waiting for nvime diff session")
assert(
  require("nvime.state").selection.last_edit_prompt:find("Previous read-only reviewer context", 1, true),
  "edit prompt includes previous ask context for same selection"
)

local session = require("nvime.state").current_diff
assert_eq(#session.hunks, 1, "one generated hunk")
assert_eq(#session.blocks, 2, "replacement diff trims unchanged trailing lines")
assert_eq(#session.visual_groups, 1, "contiguous line units render as one readable change block")
assert(session.bufnr == nil, "diff review does not open a separate diff buffer")
assert(vim.api.nvim_get_current_buf() == target, "diff review focuses the target file")
assert(#vim.api.nvim_buf_get_extmarks(target, vim.api.nvim_create_namespace("nvime.diff.inline"), 0, -1, {}) > 0, "diff review renders inline extmarks")
require("nvime.diff").accept_hunks({ session.hunks[1] })

local lines = vim.api.nvim_buf_get_lines(target, 0, -1, false)
assert_eq(lines[1], "local function add(a, b)", "applied function signature")
assert_eq(lines[2], "  return a + b", "applied function body")
assert_eq(lines[3], "end", "applied function end")

local audit = table.concat(vim.fn.readfile(audit_path), "\n")
assert(audit:find('"event":"blocked"', 1, true), "audit records blocked direct invocation")
assert(audit:find('"event":"agent_start"', 1, true), "audit records trusted agent start")
assert(audit:find('"event":"agent_exit"', 1, true), "audit records trusted agent exit")

local ok, err = pcall(require("nvime.diff").start_session, {
  bufnr = target,
  line1 = 1,
  line2 = 1,
  path = "sample.lua",
  source = "test",
}, "--- a/other.lua\n+++ b/other.lua\n@@ -1,1 +1,1 @@\n-x\n+y", "claude", "")
assert(not ok and tostring(err):find("outside the current file"), "rejects cross-file diffs")

local unchanged = require("nvime.diff").start_session({
  bufnr = target,
  line1 = 1,
  line2 = 3,
  path = "sample.lua",
  source = "test",
}, "```lua\nlocal function add(a, b)\n  return a + b\nend\n```", "claude", "")
assert(unchanged.status == "no_change", "identical replacement does not open a diff")

local prose_answer = require("nvime.diff").start_session({
  bufnr = target,
  line1 = 1,
  line2 = 3,
  path = "sample.lua",
  source = "test",
}, "Yes, this looks right. I would not change it.", "claude", "")
assert(prose_answer.status == "no_change", "plain review answer does not become a replacement")

local unchanged_diff = require("nvime.diff").start_session({
  bufnr = target,
  line1 = 1,
  line2 = 3,
  path = "sample.lua",
  source = "test",
}, "--- a/sample.lua\n+++ b/sample.lua\n@@ -1,3 +1,3 @@\n-local function add(a, b)\n+local function add(a, b)\n-  return a + b\n+  return a + b\n-end\n+end", "claude", "")
assert(unchanged_diff.status == "no_change", "semantically identical diff does not open a diff")

vim.cmd.edit(tmp .. "/generate.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "",
  "local after = true",
})
local generate_target = vim.api.nvim_get_current_buf()
local generate_result = require("nvime.diff").start_session({
  bufnr = generate_target,
  line1 = 1,
  line2 = 1,
  path = "generate.lua",
  source = "range",
}, "NVIME_REPLACEMENT\n```lua\nlocal function greet(name)\n  return \"hello \" .. name\nend\n```", "claude", "")
assert(generate_result.status == "diff", "blank selected range can generate code")
require("nvime.diff").accept_all()
local generated_lines = vim.api.nvim_buf_get_lines(generate_target, 0, -1, false)
assert_eq(
  table.concat(generated_lines, "\n"),
  "local function greet(name)\n  return \"hello \" .. name\nend\nlocal after = true",
  "generated function replaces the highlighted blank area only"
)

vim.cmd.edit(tmp .. "/.gitignore")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "node_modules/",
})
local gitignore_target = vim.api.nvim_get_current_buf()
local gitignore_result = require("nvime.diff").start_session({
  bufnr = gitignore_target,
  line1 = 1,
  line2 = 1,
  path = ".gitignore",
  source = "range",
}, "NVIME_REPLACEMENT\n```gitignore\nnode_modules/\ndist/\n.env\n*.log\n```", "claude", "")
assert(gitignore_result.status == "diff", "non-code selected range can be completed")
assert_eq(gitignore_result.session.hunks[1].old_count, 0, "completion replacement trims unchanged selected prefix")
require("nvime.diff").accept_all()
local gitignore_lines = vim.api.nvim_buf_get_lines(gitignore_target, 0, -1, false)
assert_eq(table.concat(gitignore_lines, "\n"), "node_modules/\ndist/\n.env\n*.log", "gitignore completion applies through reviewed diff")

vim.cmd.edit(tmp .. "/blocks.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local a = 1",
  "local b = 2",
  "local c = 3",
  "local d = 4",
  "local e = 5",
})
local block_target = vim.api.nvim_get_current_buf()
local block_session_result = require("nvime.diff").start_session({
  bufnr = block_target,
  line1 = 1,
  line2 = 5,
  path = "blocks.lua",
  source = "test",
}, "--- a/blocks.lua\n+++ b/blocks.lua\n@@ -1,5 +1,5 @@\n local a = 1\n-local b = 2\n+local b = 20\n local c = 3\n-local d = 4\n+local d = 40\n local e = 5", "claude", "")
assert(block_session_result.status == "diff", "multi-line inline diff opens")
assert_eq(#block_session_result.session.blocks, 2, "diff splits separated changes into line units")
assert_eq(#block_session_result.session.visual_groups, 2, "separated changes render as separate readable blocks")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
require("nvime.diff").accept_current()
local block_lines = vim.api.nvim_buf_get_lines(block_target, 0, -1, false)
assert_eq(block_lines[2], "local b = 20", "accept_current applies only the current line")
assert_eq(block_lines[4], "local d = 4", "accept_current leaves other pending lines untouched")
vim.api.nvim_win_set_cursor(0, { 4, 0 })
require("nvime.diff").reject_current()
local review_state = require("nvime.diff").remaining_text()
assert(review_state:find("Accepted lines:", 1, true), "diff discussion state includes accepted lines")
assert(review_state:find("Rejected lines:", 1, true), "diff discussion state includes rejected lines")

vim.cmd.edit(tmp .. "/unequal.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "alpha",
  "beta",
  "gamma",
})
local unequal_target = vim.api.nvim_get_current_buf()
local unequal_result = require("nvime.diff").start_session({
  bufnr = unequal_target,
  line1 = 1,
  line2 = 3,
  path = "unequal.lua",
  source = "test",
}, "--- a/unequal.lua\n+++ b/unequal.lua\n@@ -1,3 +1,4 @@\n-alpha\n-beta\n+ALPHA\n+BETA\n+EXTRA\n gamma", "claude", "")
assert_eq(#unequal_result.session.blocks, 3, "unequal replacement is still split into line units")
assert_eq(#unequal_result.session.visual_groups, 1, "unequal contiguous replacement renders as one block")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
require("nvime.diff").accept_current()
local unequal_lines = vim.api.nvim_buf_get_lines(unequal_target, 0, -1, false)
assert_eq(unequal_lines[1], "alpha", "accepting one line leaves earlier pending line unchanged")
assert_eq(unequal_lines[2], "BETA", "accepting one line applies only that changed line")
assert_eq(unequal_lines[3], "gamma", "accepting one line does not apply pending insertion")

vim.cmd.edit(tmp .. "/group.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "one",
  "two",
  "three",
})
local group_target = vim.api.nvim_get_current_buf()
local group_result = require("nvime.diff").start_session({
  bufnr = group_target,
  line1 = 1,
  line2 = 3,
  path = "group.lua",
  source = "test",
}, "--- a/group.lua\n+++ b/group.lua\n@@ -1,3 +1,3 @@\n-one\n-two\n-three\n+ONE\n+TWO\n+THREE", "claude", "")
assert_eq(#group_result.session.blocks, 3, "group fixture keeps line-level review units")
assert_eq(#group_result.session.visual_groups, 1, "group fixture renders one readable block")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ga", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local group_lines = vim.api.nvim_buf_get_lines(group_target, 0, -1, false)
  return table.concat(group_lines, "\n") == "ONE\nTWO\nTHREE"
end, 20), "normal ga accepts the whole visual block")

vim.cmd.edit(tmp .. "/accept-all.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "left",
  "middle",
  "right",
})
local accept_all_target = vim.api.nvim_get_current_buf()
require("nvime.diff").start_session({
  bufnr = accept_all_target,
  line1 = 1,
  line2 = 3,
  path = "accept-all.lua",
  source = "test",
}, "--- a/accept-all.lua\n+++ b/accept-all.lua\n@@ -1,3 +1,3 @@\n-left\n+LEFT\n middle\n-right\n+RIGHT", "claude", "")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gA", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local accept_all_lines = vim.api.nvim_buf_get_lines(accept_all_target, 0, -1, false)
  return table.concat(accept_all_lines, "\n") == "LEFT\nmiddle\nRIGHT"
end, 20), "normal gA accepts all unresolved blocks")

vim.cmd.edit(tmp .. "/deny.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "one",
  "two",
  "three",
  "four",
})
local deny_target = vim.api.nvim_get_current_buf()
local deny_result = require("nvime.diff").start_session({
  bufnr = deny_target,
  line1 = 1,
  line2 = 4,
  path = "deny.lua",
  source = "test",
}, "--- a/deny.lua\n+++ b/deny.lua\n@@ -1,4 +1,4 @@\n-one\n+ONE\n two\n-three\n+THREE\n four", "claude", "")
assert_eq(#deny_result.session.visual_groups, 2, "deny fixture renders two readable blocks")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gb", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  return deny_result.session.blocks[1].status == "rejected" and deny_result.session.blocks[2].status == "pending"
end, 20), "normal gb rejects the current visual block")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gB", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  return deny_result.session.blocks[1].status == "rejected" and deny_result.session.blocks[2].status == "rejected"
end, 20), "normal gB rejects all remaining visual blocks")
local deny_lines = vim.api.nvim_buf_get_lines(deny_target, 0, -1, false)
assert_eq(table.concat(deny_lines, "\n"), "one\ntwo\nthree\nfour", "reject bindings leave current code untouched")

vim.cmd.edit(tmp .. "/visual.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "red",
  "green",
  "blue",
})
local visual_target = vim.api.nvim_get_current_buf()
require("nvime.diff").start_session({
  bufnr = visual_target,
  line1 = 1,
  line2 = 3,
  path = "visual.lua",
  source = "test",
}, "--- a/visual.lua\n+++ b/visual.lua\n@@ -1,3 +1,3 @@\n-red\n-green\n-blue\n+RED\n+GREEN\n+BLUE", "claude", "")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Vjga", true, false, true), "xt", false)
assert(vim.wait(1000, function()
local visual_lines = vim.api.nvim_buf_get_lines(visual_target, 0, -1, false)
  return visual_lines[1] == "RED" and visual_lines[2] == "GREEN" and visual_lines[3] == "blue"
end, 20), "visual ga accepts every pending line touched by the visual range")

vim.cmd.edit(tmp .. "/large.lua")
local large_original = {}
local large_diff = {
  "--- a/large.lua",
  "+++ b/large.lua",
  "@@ -1,25 +1,25 @@",
}
for index = 1, 25 do
  large_original[#large_original + 1] = string.format("line_%02d", index)
  large_diff[#large_diff + 1] = "-" .. string.format("line_%02d", index)
end
for index = 1, 25 do
  large_diff[#large_diff + 1] = "+" .. string.format("LINE_%02d", index)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, large_original)
local large_target = vim.api.nvim_get_current_buf()
local large_result = require("nvime.diff").start_session({
  bufnr = large_target,
  line1 = 1,
  line2 = 25,
  path = "large.lua",
  source = "test",
}, table.concat(large_diff, "\n"), "claude", "")
assert_eq(#large_result.session.blocks, 25, "large contiguous diff keeps line-level review units")
assert(#large_result.session.visual_groups > 1, "large contiguous diff splits into review-sized visual blocks")
assert(#large_result.session.visual_groups[1].blocks <= 12, "default visual blocks stay small")
local first_large_group_size = #large_result.session.visual_groups[1].blocks
vim.api.nvim_win_set_cursor(0, { 1, 0 })
require("nvime.diff").accept_current_group()
local large_lines = vim.api.nvim_buf_get_lines(large_target, 0, -1, false)
assert_eq(large_lines[1], "LINE_01", "accept_current_group applies the first segmented block")
assert_eq(
  large_lines[first_large_group_size],
  string.format("LINE_%02d", first_large_group_size),
  "accept_current_group applies the end of the first segmented block"
)
assert_eq(
  large_lines[first_large_group_size + 1],
  string.format("line_%02d", first_large_group_size + 1),
  "accept_current_group leaves later visual blocks pending"
)

print("nvime headless spec passed")
