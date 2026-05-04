local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local fake_claude = root .. "/tests/fixtures/claude"
local audit_path = tmp .. "/audit.jsonl"
local sessions_path = tmp .. "/selection-sessions.json"
local chat_sessions_path = tmp .. "/chat-sessions.json"

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
  sessions = {
    path = sessions_path,
    chat_path = chat_sessions_path,
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
assert(vim.fn.maparg("<leader>nc", "n") == "<Cmd>NvimeChat<CR>", "default normal chat keymap opens chat picker")
assert(vim.fn.maparg("<leader>ne", "n") == "<Cmd>NvimeChats edit<CR>", "default normal edit keymap opens edit picker")
assert(vim.fn.maparg("<leader>nq", "n") == "<Cmd>NvimeChats ask<CR>", "default normal ask keymap opens ask picker")
assert(vim.fn.maparg("<leader>nn", "n") ~= "", "default normal last-session keymap exists")
assert(vim.fn.maparg("<leader>np", "n") ~= "", "default provider keymap exists")
assert_eq(require("nvime.progress").compact("[claude] tool: Bash: rg README"), "claude Bash", "claude progress footer keeps tool name")
assert_eq(
  require("nvime.progress").compact([[[codex] tool: /usr/bin/zsh -lc "sed -n '1,260p' README.md"]]),
  "codex tool",
  "codex command progress footer hides command text"
)
assert(vim.fn.exists(":Nvime") == 2, "Nvime command center command exists")

vim.cmd("NvimeProvider codex")
assert(require("nvime.state").config.provider == "codex", "provider command sets codex")
vim.cmd("NvimeProvider claude")
assert(require("nvime.state").config.provider == "claude", "provider command sets claude")

vim.cmd("Nvime")
local dashboard_panel = require("nvime.state").panels.chats
assert(dashboard_panel and vim.api.nvim_win_is_valid(dashboard_panel.winid), "Nvime opens the command center")
assert(dashboard_panel.mode == "dashboard", "Nvime command center uses dashboard mode")
local dashboard_lines = table.concat(vim.api.nvim_buf_get_lines(dashboard_panel.bufnr, 0, -1, false), "\n")
assert(dashboard_lines:find("Nvime", 1, true), "dashboard has branded heading")
assert(dashboard_lines:find("Actions", 1, true), "dashboard exposes action rows")
assert(
  #vim.api.nvim_buf_get_extmarks(dashboard_panel.bufnr, vim.api.nvim_create_namespace("nvime.chats"), 0, -1, {}) > 0,
  "dashboard has visual decorations"
)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("?", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local help = require("nvime.state").panels.chats_help
  return help and help.winid and vim.api.nvim_win_is_valid(help.winid)
end, 20), "dashboard help overlay opens")
pcall(vim.api.nvim_win_close, require("nvime.state").panels.chats_help.winid, true)
require("nvime.state").panels.chats_help = nil
pcall(vim.api.nvim_win_close, dashboard_panel.winid, true)

local stale_chat = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(stale_chat, "nvime://stale-chat")
local chat = require("nvime.ui").panel("stale-chat", "nvime", "nvime")
assert(chat == stale_chat, "reuses pre-existing nvime named buffer")

vim.cmd("NvimeChat")
local chat_picker_panel = require("nvime.state").panels.chats
assert(chat_picker_panel and vim.api.nvim_win_is_valid(chat_picker_panel.winid), "NvimeChat opens the general chat picker")
local chat_picker_lines = table.concat(vim.api.nvim_buf_get_lines(chat_picker_panel.bufnr, 0, -1, false), "\n")
assert(chat_picker_lines:find("General Conversations", 1, true), "chat picker is scoped to general conversations")
assert(chat_picker_lines:find("start new chat conversation", 1, true), "chat picker offers a new chat session")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("n", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local panel = require("nvime.state").panels.chat
  return panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid)
end, 20), "chat picker n opens a new general chat")
assert(vim.api.nvim_get_mode().mode ~= "i", "chat picker n opens general chat in normal mode")
assert(vim.bo[require("nvime.state").panels.chat.bufnr].modifiable == false, "newly opened chat is locked until prompt focus")

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

local fast_append_done = false
local fast_append_ok = false
local fast_append_err = nil
local fast_timer = (vim.uv or vim.loop).new_timer()
fast_timer:start(0, 0, function()
  fast_append_ok, fast_append_err = pcall(function()
    require("nvime.ui").ensure_highlights()
    require("nvime.chat").append("chat fast-event append\n")
  end)
  fast_append_done = true
  fast_timer:stop()
  fast_timer:close()
end)
assert(vim.wait(1000, function()
  return fast_append_done
end, 20), "fast-event chat append callback ran")
assert(fast_append_ok, tostring(fast_append_err))
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n"):find("chat fast-event append", 1, true)
end, 20), "chat append schedules UI work from fast events")
chat_panel = require("nvime.state").panels.chat
chat_win = chat_panel.winid
chat_input = chat_panel.input_bufnr
chat_input_win = chat_panel.input_winid

;(function()
  local dedupe_claude = tmp .. "/dedupe-claude"
  vim.fn.writefile({
    "#!/usr/bin/env sh",
    "printf '%s\\n' '{\"event\":{\"delta\":{\"type\":\"text_delta\",\"text\":\"Hey!\"}}}'",
    "printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"Hey!\"}]}}'",
  }, dedupe_claude)
  vim.fn.setfperm(dedupe_claude, "rwxr-xr-x")
  local dedupe_old_claude_cmd = require("nvime.state").config.providers.claude.cmd
  require("nvime.state").config.providers.claude.cmd = dedupe_claude
  local dedupe_chunks = {}
  local dedupe_done = false
  require("nvime.agents").run({
    provider = "claude",
    lane = "ask",
    prompt = "hello",
    on_text = function(text)
      dedupe_chunks[#dedupe_chunks + 1] = text
    end,
    on_exit = function()
      dedupe_done = true
    end,
  })
  assert(vim.wait(5000, function()
    return dedupe_done
  end, 20), "agent dedupe fixture exits")
  assert_eq(table.concat(dedupe_chunks), "Hey!", "claude streamed delta and final aggregate are not duplicated")
  require("nvime.state").config.providers.claude.cmd = dedupe_old_claude_cmd
end)()

require("nvime.chat").prompt()
assert(vim.api.nvim_get_current_buf() == chat_buf, "chat prompt focuses shared input buffer")
assert(vim.api.nvim_get_current_win() == chat_input_win, "chat prompt focuses the single chat window")
assert(vim.bo[chat_buf].modifiable == true, "chat buffer becomes editable while typing on the prompt")
local old_select = vim.ui.select
vim.ui.select = function(items, _opts, on_choice)
  on_choice(items[1])
end
require("nvime.chat").choose_prompt()
chat_panel = require("nvime.state").panels.chat
local templated_chat_prompt = vim.api.nvim_buf_get_lines(chat_buf, chat_panel.input_start - 1, chat_panel.input_start, false)[1] or ""
assert(templated_chat_prompt:find("Please review this repository", 1, true), "chat prompt picker fills the prompt line")
vim.api.nvim_buf_set_lines(chat_buf, chat_panel.input_start - 1, chat_panel.input_start, false, { "[claude]$ " })
vim.ui.select = old_select
pcall(vim.cmd.stopinsert)
require("nvime.chat").prompt()
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

local chat_scroll_lines = {}
for index = 1, 40 do
  chat_scroll_lines[#chat_scroll_lines + 1] = "chat scroll fixture " .. index
end
require("nvime.chat").append(table.concat(chat_scroll_lines, "\n") .. "\n")
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n"):find("chat scroll fixture 40", 1, true)
end, 20), "chat scroll fixture is appended")
require("nvime.state").panels.chat.input_active = false
vim.api.nvim_win_set_cursor(chat_win, { 2, 0 })
vim.api.nvim_win_call(chat_win, function()
  vim.fn.winrestview({ topline = 1 })
end)
require("nvime.chat").append("chat locked output\n")
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n"):find("chat locked output", 1, true)
end, 20), "chat locked output is appended")
local chat_locked_view = vim.api.nvim_win_call(chat_win, vim.fn.winsaveview)
assert_eq(vim.api.nvim_win_get_cursor(chat_win)[1], 2, "chat output preserves cursor when user scrolled away")
assert_eq(chat_locked_view.topline, 1, "chat output preserves topline when user scrolled away")
local chat_bottom_lnum = require("nvime.state").panels.chat.input_start
vim.api.nvim_win_set_cursor(chat_win, { chat_bottom_lnum, 0 })
vim.api.nvim_win_call(chat_win, function()
  vim.fn.winrestview({ topline = math.max(1, chat_bottom_lnum - vim.api.nvim_win_get_height(chat_win) + 2) })
end)
require("nvime.chat").append("chat following output\n")
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n"):find("chat following output", 1, true)
    and vim.api.nvim_win_get_cursor(chat_win)[1] >= require("nvime.state").panels.chat.input_start
end, 20), "chat output follows when cursor is at the prompt")

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
require("nvime.chat").save_sessions()
assert(vim.fn.filereadable(chat_sessions_path) == 1, "general chat sessions persist to disk")
local chat_sessions_json = table.concat(vim.fn.readfile(chat_sessions_path), "\n")
assert(chat_sessions_json:find("say hello", 1, true), "persisted chat sessions include transcript history")
require("nvime.chat").new_session({ title = "delete me", focus_input = false })
vim.cmd("NvimeChat")
local persisted_chat_picker = require("nvime.state").panels.chats
local persisted_chat_lines = table.concat(vim.api.nvim_buf_get_lines(persisted_chat_picker.bufnr, 0, -1, false), "\n")
assert(persisted_chat_lines:find("say hello", 1, true), "chat picker shows old conversations by title")
assert(persisted_chat_lines:find("delete me", 1, true), "chat picker shows newly created conversations")
local delete_chat_row = nil
for row, _ in pairs(persisted_chat_picker.row_to_session or {}) do
  local line = vim.api.nvim_buf_get_lines(persisted_chat_picker.bufnr, row - 1, row, false)[1] or ""
  if line:find("delete me", 1, true) then
    delete_chat_row = row
    break
  end
end
assert(delete_chat_row ~= nil, "chat picker has a deletable chat row")
vim.api.nvim_win_set_cursor(persisted_chat_picker.winid, { delete_chat_row, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("dd", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  return not table.concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.chats.bufnr, 0, -1, false), "\n")
    :find("delete me", 1, true)
end, 20), "chat picker dd deletes the selected chat session")
assert(require("nvime.chat").session_count() >= 1, "deleting one chat keeps older conversations")
require("nvime.chat").save_sessions()
require("nvime.chat").reload_sessions()
assert(require("nvime.chat").session_count() >= 1, "general chat sessions reload from disk")
vim.cmd("NvimeChat")
local reloaded_chat_picker = require("nvime.state").panels.chats
assert(
  table.concat(vim.api.nvim_buf_get_lines(reloaded_chat_picker.bufnr, 0, -1, false), "\n"):find("say hello", 1, true),
  "chat picker shows persisted conversations after reload"
)
local reloaded_chat = require("nvime.chat").sessions()[1]
vim.api.nvim_set_current_win(reloaded_chat_picker.winid)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("1", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local panel = require("nvime.state").panels.chat
  return require("nvime.chat").active_session_id() == reloaded_chat.id
    and panel
    and panel.winid
    and vim.api.nvim_win_is_valid(panel.winid)
end, 20), "chat picker numeric shortcut opens the first conversation")
assert(vim.api.nvim_get_mode().mode ~= "i", "chat picker numeric shortcut opens chat in normal mode")
assert(vim.bo[require("nvime.state").panels.chat.bufnr].modifiable == false, "opened chat session is locked until prompt focus")
chat_buf = require("nvime.state").panels.chat.bufnr
chat_panel = require("nvime.state").panels.chat
chat_win = chat_panel.winid
chat_input = chat_panel.input_bufnr
chat_input_win = chat_panel.input_winid

local old_claude_cmd = require("nvime.state").config.providers.claude.cmd
local chat_progress_claude = tmp .. "/chat-progress-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"sed -n 1,260p README.md\"}}]}}'",
  "sleep 0.2",
  "printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"progress final\"}]}}'",
}, chat_progress_claude)
vim.fn.setfperm(chat_progress_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = chat_progress_claude
local progress_history_start = #require("nvime.state").chat.history
require("nvime.chat").submit("progress flush chat")
assert(vim.wait(5000, function()
  return require("nvime.state").chat.progress == "claude Bash"
end, 20), "chat progress is visible while the provider runs")
local saw_progress_virtual_text = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(chat_buf, vim.api.nvim_create_namespace("nvime.chat.input"), 0, -1, {
  details = true,
})) do
  for _, chunk in ipairs((mark[4] or {}).virt_text or {}) do
    saw_progress_virtual_text = saw_progress_virtual_text or tostring(chunk[1]):find("claude Bash", 1, true) ~= nil
  end
end
assert(saw_progress_virtual_text, "chat progress is shown as prompt-line virtual text")
assert(vim.wait(5000, function()
  return #require("nvime.state").chat.history >= progress_history_start + 2
end, 20), "chat progress fixture runs")
local progress_flush_transcript = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(progress_flush_transcript:find("progress final", 1, true), "chat progress fixture delivers final answer")
assert(not progress_flush_transcript:find("tool: Bash", 1, true), "chat progress is not appended to transcript")
assert(require("nvime.state").chat.progress == nil, "chat progress is cleared after completion")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

local chat_native_claude_id = "33333333-3333-3333-3333-333333333333"
local fake_chat_resume_claude = tmp .. "/fake-chat-resume-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' '{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"" .. chat_native_claude_id .. "\"}'",
  "printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"native chat ok\"}]}}'",
}, fake_chat_resume_claude)
vim.fn.setfperm(fake_chat_resume_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = fake_chat_resume_claude
require("nvime.state").chat.provider_sessions = {}
require("nvime.state").chat.provider_workspaces = {}
require("nvime.state").chat.last_provider = nil
local native_chat_start = #require("nvime.state").chat.history
require("nvime.chat").submit("first native chat")
assert(vim.wait(5000, function()
  return #require("nvime.state").chat.history >= native_chat_start + 2
end, 20), "native chat first turn runs")
assert_eq(
  require("nvime.state").chat.provider_sessions.claude,
  chat_native_claude_id,
  "general chat captures native claude session id"
)
local native_chat_followup = #require("nvime.state").chat.history
require("nvime.chat").submit("second native chat")
assert(vim.wait(5000, function()
  return #require("nvime.state").chat.history >= native_chat_followup + 2
end, 20), "native chat follow-up runs")
local native_chat_audit = vim.fn.readfile(audit_path)
local first_native_chat = ""
local second_native_chat = ""
for _, line in ipairs(native_chat_audit) do
  if line:find("first native chat", 1, true) then
    first_native_chat = line
  elseif line:find("second native chat", 1, true) then
    second_native_chat = line
  end
end
assert(not first_native_chat:find("--no-session-persistence", 1, true), "general chat keeps native session persistence")
assert(second_native_chat:find("--resume " .. chat_native_claude_id, 1, true), "general chat follow-up uses native resume")
assert(second_native_chat:find("Conversation so far: available from the resumed native provider session", 1, true), "resumed chat avoids resending full transcript")
local first_native_chat_event = vim.json.decode(first_native_chat)
local second_native_chat_event = vim.json.decode(second_native_chat)
assert_eq(
  first_native_chat_event.markdown_workspace,
  second_native_chat_event.markdown_workspace,
  "general chat reuses one markdown workspace for native resume"
)
assert_eq(first_native_chat_event.cwd, first_native_chat_event.markdown_workspace, "general chat runs inside the stable markdown workspace")
assert_eq(second_native_chat_event.cwd, second_native_chat_event.markdown_workspace, "resumed general chat stays in the stable markdown workspace")

local stale_chat_claude = tmp .. "/stale-chat-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' 'No conversation found with session ID: stale-chat-id' >&2",
  "exit 1",
}, stale_chat_claude)
vim.fn.setfperm(stale_chat_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = stale_chat_claude
require("nvime.state").chat.provider_sessions = { claude = "stale-chat-id" }
require("nvime.state").chat.provider_workspaces = {}
require("nvime.state").chat.last_provider = "claude"
require("nvime.chat").submit("stale native chat")
assert(vim.wait(5000, function()
  local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
  return text:find("No conversation found with session ID: stale-chat-id", 1, true)
    and text:find("[nvime] chat failed with code 1", 1, true)
end, 20), "general chat dumps stale native resume errors")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd
require("nvime.state").chat.provider_sessions = {}
require("nvime.state").chat.provider_workspaces = {}
require("nvime.state").chat.last_provider = nil

local hidden_chat_claude = tmp .. "/hidden-chat-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "sleep 0.2",
  "printf '%s\\n' '{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"hidden chat done\"}]}}'",
}, hidden_chat_claude)
vim.fn.setfperm(hidden_chat_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = hidden_chat_claude
local old_notify = vim.notify
local notices = {}
vim.notify = function(msg, level, opts)
  notices[#notices + 1] = tostring(msg)
  return old_notify(msg, level, opts)
end
require("nvime.chat").submit("hidden chat notify")
local hidden_chat_id = require("nvime.chat").active_session_id()
require("nvime.chat").close()
assert(not require("nvime.chat").is_open(hidden_chat_id), "hidden chat fixture closes the float while running")
assert(vim.wait(5000, function()
  local session = require("nvime.chat").get_session(hidden_chat_id)
  return session and not session.busy and table.concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n"):find("hidden chat done", 1, true)
end, 20), "hidden chat still records the completed response")
assert(not require("nvime.chat").is_open(hidden_chat_id), "hidden chat completion does not reopen the float")
assert(vim.tbl_contains(notices, "nvime chat finished. Reopen with :NvimeLast or <leader>nn."), "hidden chat completion notifies")
vim.notify = old_notify
require("nvime").open_last()
assert(require("nvime.chat").is_open(hidden_chat_id), "NvimeLast reopens the hidden completed chat")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

local writer_claude = tmp .. "/writer-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' '# Generated by nvime test' > NVIME_TEST_DOC.md",
  "printf '%s\\n' 'source writes must not sync' > SHOULD_NOT_SYNC.lua",
  "printf '%s\\n' 'wrote markdown'",
}, writer_claude)
vim.fn.setfperm(writer_claude, "rwxr-xr-x")
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
assert(
  first_native_claude:find("--tools Read,Glob,Grep,LS,WebFetch,WebSearch,Bash", 1, true),
  "claude selection lane allows read/search/web/shell tools"
)
assert(
  first_native_claude:find("--allowedTools Read,Glob,Grep,LS,WebFetch,WebSearch,Bash", 1, true),
  "claude selection allow-list is explicit"
)
assert(
  first_native_claude:find("--disallowedTools Edit,Write,MultiEdit,NotebookEdit", 1, true),
  "claude selection lane blocks direct write tools"
)
assert(second_native_claude:find("--resume " .. native_claude_id, 1, true), "claude follow-up uses native resume")
local old_selection_allow_shell = require("nvime.state").config.selection.allow_shell
local old_selection_allow_web = require("nvime.state").config.selection.allow_web
require("nvime.state").config.selection.allow_shell = false
native_claude_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "no shell native claude",
  persist_session = true,
  on_exit = function(result)
    native_claude_done = result.code == 0
  end,
})
assert(vim.wait(5000, function()
  return native_claude_done
end, 20), "claude selection lane can disable shell tools")
require("nvime.state").config.selection.allow_shell = old_selection_allow_shell
native_claude_audit = vim.fn.readfile(audit_path)
local no_shell_native_claude = ""
for _, line in ipairs(native_claude_audit) do
  if line:find("no shell native claude", 1, true) then
    no_shell_native_claude = line
  end
end
assert(
  no_shell_native_claude:find("--tools Read,Glob,Grep,LS,WebFetch,WebSearch", 1, true),
  "claude selection keeps web tools when shell is disabled"
)
assert(not no_shell_native_claude:find("Bash", 1, true), "claude selection omits Bash when selection shell is disabled")
require("nvime.state").config.selection.allow_web = false
native_claude_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "no web native claude",
  persist_session = true,
  on_exit = function(result)
    native_claude_done = result.code == 0
  end,
})
assert(vim.wait(5000, function()
  return native_claude_done
end, 20), "claude selection lane can disable web tools")
require("nvime.state").config.selection.allow_shell = old_selection_allow_shell
require("nvime.state").config.selection.allow_web = old_selection_allow_web
native_claude_audit = vim.fn.readfile(audit_path)
local no_web_native_claude = ""
for _, line in ipairs(native_claude_audit) do
  if line:find("no web native claude", 1, true) then
    no_web_native_claude = line
  end
end
assert(no_web_native_claude:find("--tools Read,Glob,Grep,LS", 1, true), "claude selection can omit web tools")
assert(
  not no_web_native_claude:find("--tools Read,Glob,Grep,LS,WebFetch", 1, true),
  "claude selection omits WebFetch from the allowed tool list when selection web is disabled"
)
assert(
  no_web_native_claude:find("--disallowedTools Edit,Write,MultiEdit,NotebookEdit,WebFetch,WebSearch", 1, true),
  "claude selection explicitly disallows web tools when disabled"
)
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
  "printf '%s\\n' '2026-05-04T19:02:05.488995Z ERROR codex_models_manager::manager: failed to refresh available models: timeout waiting for child process to exit' >&2",
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
assert(not table.concat(codex_text):find("failed to refresh available models", 1, true), "codex model refresh stderr noise is not transcript text")
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
require("nvime.selection").save_sessions()
assert(vim.fn.filereadable(sessions_path) == 1, "selection discussions persist to disk")
local persisted_json = table.concat(vim.fn.readfile(sessions_path), "\n")
assert(persisted_json:find("nvime%-chat%.txt", 1, false), "persisted discussions include selection metadata")
assert(persisted_json:find("local function add", 1, true), "persisted discussions include transcript text")
local persisted_panel = require("nvime.state").panels.selection
if persisted_panel and persisted_panel.winid and vim.api.nvim_win_is_valid(persisted_panel.winid) then
  pcall(vim.api.nvim_win_close, persisted_panel.winid, true)
end
require("nvime.state").panels.selection = nil
require("nvime.selection").reload_sessions()
assert(require("nvime.selection").session_count() == 1, "selection discussions reload from disk")
local persisted_session = require("nvime.selection").sessions()[1]
assert(persisted_session and persisted_session.selection.path == "nvime-chat.txt", "reloaded discussion keeps file/range")
require("nvime.selection").open_session(persisted_session.id, { focus_input = false })
assert(
  table.concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.selection.bufnr, 0, -1, false), "\n")
    :find("local function add", 1, true),
  "reopened persisted discussion restores transcript"
)
local selection_panel_for_scroll = require("nvime.state").panels.selection
local selection_scroll_lines = {}
for index = 1, 40 do
  selection_scroll_lines[#selection_scroll_lines + 1] = "selection scroll fixture " .. index
end
require("nvime.selection").append(
  table.concat(selection_scroll_lines, "\n") .. "\n",
  require("nvime.selection").active_session_id()
)
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(selection_panel_for_scroll.bufnr, 0, -1, false), "\n")
    :find("selection scroll fixture 40", 1, true)
end, 20), "selection scroll fixture is appended")
require("nvime.state").panels.selection.input_active = false
vim.api.nvim_win_set_cursor(selection_panel_for_scroll.winid, { 2, 0 })
vim.api.nvim_win_call(selection_panel_for_scroll.winid, function()
  vim.fn.winrestview({ topline = 1 })
end)
require("nvime.selection").append("selection locked output\n", require("nvime.selection").active_session_id())
assert(vim.wait(1000, function()
  return table.concat(vim.api.nvim_buf_get_lines(selection_panel_for_scroll.bufnr, 0, -1, false), "\n")
    :find("selection locked output", 1, true)
end, 20), "selection locked output is appended")
local selection_locked_view = vim.api.nvim_win_call(selection_panel_for_scroll.winid, vim.fn.winsaveview)
assert_eq(
  vim.api.nvim_win_get_cursor(selection_panel_for_scroll.winid)[1],
  2,
  "selection output preserves cursor when user scrolled away"
)
assert_eq(selection_locked_view.topline, 1, "selection output preserves topline when user scrolled away")
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
local numeric_discussion = require("nvime.selection").sessions()[1]
assert(numeric_discussion ~= nil, "chats picker has a persisted discussion row to reopen")
vim.api.nvim_set_current_win(chats_panel.winid)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("1", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local panel = require("nvime.state").panels.selection
  return panel
    and panel.bufnr == selection_session_buf
    and panel.winid
    and vim.api.nvim_win_is_valid(panel.winid)
    and require("nvime.selection").active_session_id() == numeric_discussion.id
end, 20), "ask picker numeric shortcut reopens the first discussion")
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
vim.cmd("NvimeChats edit")
local edit_chats_panel = require("nvime.state").panels.chats
local numeric_edit_discussion = require("nvime.selection").sessions()[1]
assert(edit_chats_panel and vim.api.nvim_win_is_valid(edit_chats_panel.winid), "NvimeChats edit opens a floating picker")
assert(numeric_edit_discussion ~= nil, "edit picker has a persisted discussion row to reopen")
vim.api.nvim_set_current_win(edit_chats_panel.winid)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("1", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  local panel = require("nvime.state").panels.selection
  return panel
    and panel.winid
    and vim.api.nvim_win_is_valid(panel.winid)
    and require("nvime.selection").active_session_id() == numeric_edit_discussion.id
end, 20), "edit picker numeric shortcut reopens the first discussion")
local edit_numeric_prompt = table.concat(
  vim.api.nvim_buf_get_lines(
    require("nvime.state").panels.selection.bufnr,
    require("nvime.state").panels.selection.input_start - 1,
    -1,
    false
  ),
  "\n"
)
assert(edit_numeric_prompt:find("[claude edit]$ ", 1, true), "edit picker numeric shortcut arms the edit prompt")
assert(vim.api.nvim_get_mode().mode ~= "i", "edit picker numeric shortcut opens in normal mode")
assert(vim.bo[require("nvime.state").panels.selection.bufnr].modifiable == false, "edit picker numeric shortcut keeps prompt locked until input focus")
;(function()
  local normal_enter_claude = tmp .. "/normal-enter-claude"
  vim.fn.writefile({
    "#!/usr/bin/env sh",
    "printf '%s\\n' 'NVIME_NO_CHANGE'",
    "printf '%s\\n' 'normal enter submitted'",
  }, normal_enter_claude)
  vim.fn.setfperm(normal_enter_claude, "rwxr-xr-x")
  local normal_enter_old_cmd = require("nvime.state").config.providers.claude.cmd
  require("nvime.state").config.providers.claude.cmd = normal_enter_claude
  require("nvime.selection").focus_input()
  local panel = require("nvime.state").panels.selection
  vim.api.nvim_buf_set_lines(panel.bufnr, panel.input_start - 1, panel.input_start, false, {
    "[claude edit]$ hey",
  })
  pcall(vim.cmd.stopinsert)
  panel.input_active = false
  vim.bo[panel.bufnr].modifiable = false
  vim.api.nvim_set_current_win(panel.winid)
  vim.api.nvim_win_set_cursor(panel.winid, { panel.input_start, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
  assert(vim.wait(5000, function()
    local session = require("nvime.selection").get_session(require("nvime.selection").active_session_id())
    return session
      and table.concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n")
        :find("normal enter submitted", 1, true)
  end, 20), "normal-mode Enter submits a filled selection prompt after reopening a discussion")
  require("nvime.state").config.providers.claude.cmd = normal_enter_old_cmd
end)()
vim.cmd("NvimeChats ask")
local delete_panel = require("nvime.state").panels.chats
local delete_row = nil
for row, _ in pairs(delete_panel.row_to_session or {}) do
  delete_row = row
  break
end
assert(delete_row ~= nil, "chats picker has a persisted discussion row to delete")
vim.api.nvim_win_set_cursor(delete_panel.winid, { delete_row, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("dd", true, false, true), "xt", false)
assert(vim.wait(1000, function()
  return require("nvime.selection").session_count() == 0
end, 20), "chats picker dd deletes the selected discussion")
require("nvime.selection").save_sessions()
local after_delete_json = table.concat(vim.fn.readfile(sessions_path), "\n")
assert(not after_delete_json:find("nvime%-chat%.txt"), "deleted discussions are removed from persisted sessions")

;(function()
  local stale_selection_file = tmp .. "/stale-selection.lua"
  vim.fn.writefile({
    "local function stale()",
    "  return true",
    "end",
  }, stale_selection_file)
  vim.cmd.edit(stale_selection_file)
  local stale_selection_buf = vim.api.nvim_get_current_buf()
  require("nvime.selection").open({
    provider = "claude",
    mode = "edit",
    selection = {
      bufnr = stale_selection_buf,
      line1 = 1,
      line2 = 3,
      path = stale_selection_file,
      source = "test",
    },
    new_session = true,
  })
  local stale_selection_session_id = require("nvime.selection").active_session_id()
  require("nvime.selection").save_sessions()
  pcall(vim.api.nvim_buf_delete, stale_selection_buf, { force = true })
  require("nvime.selection").reload_sessions()
  local stale_no_change_claude = tmp .. "/stale-no-change-claude"
  vim.fn.writefile({
    "#!/usr/bin/env sh",
    "printf '%s\\n' 'NVIME_NO_CHANGE'",
    "printf '%s\\n' 'stale persisted selection reattached'",
  }, stale_no_change_claude)
  vim.fn.setfperm(stale_no_change_claude, "rwxr-xr-x")
  local stale_old_claude_cmd = require("nvime.state").config.providers.claude.cmd
  require("nvime.state").config.providers.claude.cmd = stale_no_change_claude
  local stale_session = require("nvime.selection").get_session(stale_selection_session_id)
  assert(stale_session and stale_session.selection.bufnr == nil, "persisted selection reload drops stale buffer ids")
  require("nvime.edit").start({
    provider = "claude",
    selection = stale_session.selection,
    session_id = stale_selection_session_id,
  })
  require("nvime.selection").focus_input()
  local stale_panel = require("nvime.state").panels.selection
  vim.api.nvim_buf_set_lines(stale_panel.bufnr, stale_panel.input_start - 1, stale_panel.input_start, false, {
    "[claude edit]$ please fix",
  })
  local stale_submit_ok, stale_submit_err = pcall(require("nvime.selection").submit_current)
  assert(stale_submit_ok, tostring(stale_submit_err))
  assert(vim.wait(5000, function()
    local session = require("nvime.selection").get_session(stale_selection_session_id)
    return session
      and table.concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n")
        :find("stale persisted selection reattached", 1, true)
  end, 20), "persisted selection sessions reattach by path before submit")
  require("nvime.state").config.providers.claude.cmd = stale_old_claude_cmd
  require("nvime.selection").delete_sessions({ stale_selection_session_id })
end)()

require("nvime.ask").start({
  provider = "claude",
  selection = {
    bufnr = chat_buf,
    line1 = 1,
    line2 = 1,
    path = "nvime-chat.txt",
    source = "test",
  },
  new_session = true,
})
local prompt_only_session_id = require("nvime.selection").active_session_id()
assert(vim.api.nvim_get_mode().mode ~= "i", "selection prompt opens in normal mode")
assert(vim.bo[require("nvime.state").panels.selection.bufnr].modifiable == false, "selection prompt is locked until input focus")
local old_select_selection = vim.ui.select
vim.ui.select = function(items, _opts, on_choice)
  on_choice(items[1])
end
require("nvime.selection").choose_prompt()
local templated_selection_prompt = vim.api.nvim_buf_get_lines(
  require("nvime.state").panels.selection.bufnr,
  require("nvime.state").panels.selection.input_start - 1,
  require("nvime.state").panels.selection.input_start,
  false
)[1] or ""
assert(templated_selection_prompt:find("Please review this selection", 1, true), "selection prompt picker fills the prompt line")
vim.ui.select = old_select_selection
pcall(vim.cmd.stopinsert)
require("nvime.selection").delete_sessions({ prompt_only_session_id })

local hidden_ask_claude = tmp .. "/hidden-ask-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "sleep 0.2",
  "printf '%s\\n' 'hidden ask done'",
}, hidden_ask_claude)
vim.fn.setfperm(hidden_ask_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = hidden_ask_claude
local old_notify_selection = vim.notify
local selection_notices = {}
vim.notify = function(msg, level, opts)
  selection_notices[#selection_notices + 1] = tostring(msg)
  return old_notify_selection(msg, level, opts)
end
require("nvime.ask").start({
  provider = "claude",
  question = "finish while hidden",
  selection = {
    bufnr = chat_buf,
    line1 = 1,
    line2 = 1,
    path = "nvime-chat.txt",
    source = "test",
  },
  new_session = true,
})
local hidden_ask_session_id = require("nvime.selection").active_session_id()
require("nvime.selection").close()
assert(not require("nvime.selection").is_open(hidden_ask_session_id), "hidden ask fixture closes the float while running")
assert(vim.wait(5000, function()
  local session = require("nvime.selection").get_session(hidden_ask_session_id)
  return session and not session.busy and table.concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n"):find("hidden ask done", 1, true)
end, 20), "hidden ask still records the completed response")
assert(not require("nvime.selection").is_open(hidden_ask_session_id), "hidden ask completion does not reopen the float")
assert(vim.wait(1000, function()
  return vim.tbl_contains(selection_notices, "nvime ask finished. Reopen with :NvimeLast or <leader>nn.")
end, 20), "hidden ask completion notifies")
vim.notify = old_notify_selection
require("nvime").open_last()
assert(require("nvime.selection").is_open(hidden_ask_session_id), "NvimeLast reopens the hidden completed selection discussion")
require("nvime.selection").delete_sessions({ hidden_ask_session_id })
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

vim.cmd.edit(tmp .. "/visual-resume.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local previous = true",
  "local current = true",
})
local visual_resume_buf = vim.api.nvim_get_current_buf()
require("nvime.selection").open({
  provider = "codex",
  mode = "ask",
  selection = {
    bufnr = visual_resume_buf,
    line1 = 1,
    line2 = 1,
    path = "visual-resume.lua",
    source = "test",
  },
  new_session = true,
})
local old_visual_session_id = require("nvime.selection").active_session_id()
local old_visual_session = require("nvime.selection").get_session(old_visual_session_id)
old_visual_session.provider_sessions.codex = "codex-visual-resume"
require("nvime.selection").append("previous repo context\n", old_visual_session_id)
assert(vim.wait(1000, function()
  local session = require("nvime.selection").get_session(old_visual_session_id)
  return session and table.concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n"):find("previous repo context", 1, true)
end, 20), "visual resume fixture has persisted context")
require("nvime.selection").save_sessions()
require("nvime.selection").reload_sessions()
local old_select = vim.ui.select
local visual_resume_choices = nil
vim.ui.select = function(items, _opts, on_choice)
  visual_resume_choices = items
  for _, item in ipairs(items) do
    if item.session_id == old_visual_session_id then
      on_choice(item)
      return
    end
  end
  on_choice(items[1])
end
require("nvime.ask").start({
  provider = "claude",
  question = "can we continue this older context on the current line?",
  choose_session = true,
  selection = {
    bufnr = visual_resume_buf,
    line1 = 2,
    line2 = 2,
    path = "visual-resume.lua",
    source = "test",
  },
})
vim.ui.select = old_select
assert(visual_resume_choices and #visual_resume_choices >= 2, "visual selection chooser offers previous discussions")
assert(visual_resume_choices[2].label:find("same file", 1, true), "visual selection chooser labels same-file discussions")
assert(vim.wait(5000, function()
  local ask = require("nvime.state").selection.last_ask
  return require("nvime.selection").active_session_id() == old_visual_session_id
    and ask
    and ask.selection.path == "visual-resume.lua"
    and tonumber(ask.selection.line1) == 2
end, 20), "visual selection can resume an older persisted discussion for a new range")
local resumed_visual_session = require("nvime.selection").get_session(old_visual_session_id)
assert_eq(resumed_visual_session.provider, "codex", "resuming a previous discussion keeps its provider")
assert_eq(resumed_visual_session.selection.line1, 2, "resumed discussion attaches the newly highlighted range")
assert_eq(resumed_visual_session.key, "visual-resume.lua:2:2", "resumed discussion updates future range matching")
require("nvime.selection").delete_sessions({ old_visual_session_id })

local ask_diff_claude = tmp .. "/ask-diff-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' '```diff'",
  "printf '%s\\n' '--- a/askdiff.lua'",
  "printf '%s\\n' '+++ b/askdiff.lua'",
  "printf '%s\\n' '@@ -1,1 +1,1 @@'",
  "printf '%s\\n' '-local value = 1'",
  "printf '%s\\n' '+local value = 2'",
  "printf '%s\\n' '```'",
}, ask_diff_claude)
vim.fn.setfperm(ask_diff_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = ask_diff_claude
vim.cmd.edit(tmp .. "/askdiff.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 1" })
local ask_diff_target = vim.api.nvim_get_current_buf()
require("nvime.state").current_diff = nil
require("nvime.ask").start({
  provider = "claude",
  question = "could you suggest the diff so I can approve it?",
  selection = {
    bufnr = ask_diff_target,
    line1 = 1,
    line2 = 1,
    path = "askdiff.lua",
    source = "test",
  },
})
assert(vim.wait(5000, function()
  local session = require("nvime.state").current_diff
  return session and session.file == "askdiff.lua" and session.selection_session_id ~= nil
end, 20), "ask response containing a current-file diff opens inline review")
local ask_diff_panel = require("nvime.state").panels.selection
assert(
  not ask_diff_panel or not ask_diff_panel.winid or not vim.api.nvim_win_is_valid(ask_diff_panel.winid),
  "ask output float closes when an inline diff opens"
)
require("nvime.diff").reject_all()
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

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
  "[claude ask]$ can you please suggest the diff so i can approve it",
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
assert(
  require("nvime.state").selection.last_edit_prompt:find("Return exactly one machine-readable response block", 1, true),
  "edit prompt uses a strict machine-readable patch contract"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("Do not write analysis", 1, true),
  "edit prompt forbids prose outside the patch block"
)
local closed_selection_panel = require("nvime.state").panels.selection
assert(
  not closed_selection_panel
    or not closed_selection_panel.winid
    or not vim.api.nvim_win_is_valid(closed_selection_panel.winid),
  "selection output float closes when an inline diff opens"
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

local no_patch_claude = tmp .. "/no-patch-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' 'I do not have a concrete patch for this request.'",
}, no_patch_claude)
vim.fn.setfperm(no_patch_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = no_patch_claude
vim.cmd.edit(tmp .. "/no-patch.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local function add(a,b)",
  "  return a-b",
  "end",
})
local no_patch_target = vim.api.nvim_get_current_buf()
require("nvime.state").current_diff = nil
require("nvime.edit").start({
  provider = "claude",
  intent = "please fix this",
  selection = {
    bufnr = no_patch_target,
    line1 = 1,
    line2 = 3,
    path = "no-patch.lua",
    source = "test",
  },
})
assert(vim.wait(5000, function()
  local transcript = table.concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.selection.bufnr, 0, -1, false), "\n")
  return transcript:find("no patch opened", 1, true) ~= nil
end, 20), "edit no-patch result is reported")
assert(
  require("nvime.state").selection.pending_input
    and require("nvime.state").selection.pending_input.mode == "edit"
    and type(require("nvime.state").selection.pending_input.on_submit) == "function",
  "edit no-patch result re-arms the edit prompt"
)
require("nvime.state").config.providers.claude.cmd = old_claude_cmd
require("nvime.selection").focus_input()
local no_patch_panel = require("nvime.state").panels.selection
vim.api.nvim_buf_set_lines(no_patch_panel.bufnr, no_patch_panel.input_start - 1, no_patch_panel.input_start, false, {
  "[claude edit]$ please fix",
})
require("nvime.selection").submit_current()
assert(vim.wait(5000, function()
  local followup_diff = require("nvime.state").current_diff
  return followup_diff and followup_diff.file == "no-patch.lua"
end, 20), "edit follow-up prompt submits after a no-patch result")
require("nvime.diff").reject_all()

local review_route_claude = tmp .. "/review-route-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' 'Review only: one thing may need a follow-up patch.'",
}, review_route_claude)
vim.fn.setfperm(review_route_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = review_route_claude
require("nvime.state").selection.last_ask = nil
require("nvime.state").current_diff = nil
require("nvime.edit").start({
  provider = "claude",
  intent = "please iterate throughout this readme and ensure correctness. Be nitpicky.",
  selection = {
    bufnr = no_patch_target,
    line1 = 1,
    line2 = 3,
    path = "no-patch.lua",
    source = "test",
  },
})
assert(vim.wait(5000, function()
  local ask = require("nvime.state").selection.last_ask
  return ask and ask.question:find("nitpicky", 1, true)
end, 20), "review-shaped edit prompt routes to ask")
assert(require("nvime.state").current_diff == nil, "review-shaped edit prompt does not open a diff")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

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

vim.cmd.edit(tmp .. "/nested-fence.md")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "# nvime",
  "",
  "```lua",
  "local value = 1",
  "```",
  "",
  "tail",
})
local nested_fence_target = vim.api.nvim_get_current_buf()
local nested_fence_result = require("nvime.diff").start_session({
  bufnr = nested_fence_target,
  line1 = 1,
  line2 = 7,
  path = "nested-fence.md",
  source = "test",
}, "NVIME_REPLACEMENT\n````markdown\n# nvime\n\n```lua\nlocal value = 2\n```\n\ntail\n````", "claude", "")
assert_eq(nested_fence_result.session.hunks[1].old_start, 4, "four-backtick replacement strips the outer fence")
assert_eq(#nested_fence_result.session.blocks, 1, "nested fenced markdown replacement only changes the edited line")
assert_eq(nested_fence_result.session.blocks[1].old_lines[1], "local value = 1", "nested replacement keeps original changed line")
assert_eq(nested_fence_result.session.blocks[1].new_lines[1], "local value = 2", "nested replacement keeps proposed changed line")
require("nvime.diff").reject_all()
local prefaced_fence_result = require("nvime.diff").start_session({
  bufnr = nested_fence_target,
  line1 = 1,
  line2 = 7,
  path = "nested-fence.md",
  source = "test",
}, "I found one issue.\n\nNVIME_REPLACEMENT\n````markdown\n# nvime\n\n```lua\nlocal value = 3\n```\n\ntail\n````", "claude", "")
assert_eq(prefaced_fence_result.session.hunks[1].old_start, 4, "replacement parser finds NVIME mode after prose")
assert_eq(prefaced_fence_result.session.blocks[1].new_lines[1], "local value = 3", "prefaced replacement keeps nested fence content")
require("nvime.diff").reject_all()

vim.cmd.edit(tmp .. "/bare-diff.md")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "# install",
  "The plugin auto-registers with defaults when it is on `runtimepath`, so no",
  "explicit `setup` call is required to use it; call `require(\"nvime\").setup({ ... })`",
  "## next",
})
local bare_diff_target = vim.api.nvim_get_current_buf()
local bare_diff_result = require("nvime.diff").start_session({
  bufnr = bare_diff_target,
  line1 = 1,
  line2 = 4,
  path = "bare-diff.md",
  source = "test",
}, "NVIME_DIFF\n```diff\n@@\n The plugin auto-registers with defaults when it is on `runtimepath`, so no\n-explicit `setup` call is required to use it; call `require(\"nvime\").setup({ ... })`\n+explicit `setup` call is required. Call `require(\"nvime\").setup({ ... })` only\n+when you want to override the defaults shown below.\n```", "claude", "")
assert_eq(bare_diff_result.status, "diff", "bare @@ NVIME_DIFF is anchored into a reviewed hunk")
assert_eq(bare_diff_result.session.hunks[1].old_start, 2, "bare @@ diff anchors on selected context")
assert_eq(#bare_diff_result.session.blocks, 2, "bare @@ diff creates line-level review blocks")
require("nvime.diff").accept_all()
local bare_diff_lines = vim.api.nvim_buf_get_lines(bare_diff_target, 0, -1, false)
assert_eq(
  table.concat(bare_diff_lines, "\n"),
  "# install\nThe plugin auto-registers with defaults when it is on `runtimepath`, so no\nexplicit `setup` call is required. Call `require(\"nvime\").setup({ ... })` only\nwhen you want to override the defaults shown below.\n## next",
  "bare @@ diff applies through inline review"
)

vim.cmd.edit(tmp .. "/lazy-install.md")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "```lua",
  "{",
  "  \"mengsig/nvime\",",
  "  opts = {},",
  "}",
  "```",
  "",
  "With lazy.nvim, `opts = {}` is enough because lazy calls `setup({})` for you.",
  "If the plugin is loaded directly from `runtimepath`, `plugin/nvime.lua`",
  "registers the defaults. Call `require(\"nvime\").setup({ ... })` only when you",
  "want to override them.",
})
local lazy_install_target = vim.api.nvim_get_current_buf()
local lazy_install_result = require("nvime.diff").start_session({
  bufnr = lazy_install_target,
  line1 = 8,
  line2 = 11,
  path = "lazy-install.md",
  source = "test",
}, "NVIME_DIFF\n```diff\n--- a/lazy-install.md\n+++ b/lazy-install.md\n@@ -6,6 +6,7 @@\n```\n\n-With lazy.nvim, `opts = {}` is enough because lazy calls `setup({})` for you.\n+With lazy.nvim, `opts = {}` is enough because lazy calls `setup({})` for you,\n+and it is where you can pass overrides.\n If the plugin is loaded directly from `runtimepath`, `plugin/nvime.lua`\n registers the defaults. Call `require(\"nvime\").setup({ ... })` only when you\n want to override them.\n```", "codex", "")
assert_eq(lazy_install_result.status, "diff", "agent diff with unprefixed context lines still opens a patch")
require("nvime.diff").accept_all()
local lazy_install_lines = vim.api.nvim_buf_get_lines(lazy_install_target, 0, -1, false)
assert_eq(
  table.concat(lazy_install_lines, "\n"),
  "```lua\n{\n  \"mengsig/nvime\",\n  opts = {},\n}\n```\n\nWith lazy.nvim, `opts = {}` is enough because lazy calls `setup({})` for you,\nand it is where you can pass overrides.\nIf the plugin is loaded directly from `runtimepath`, `plugin/nvime.lua`\nregisters the defaults. Call `require(\"nvime\").setup({ ... })` only when you\nwant to override them.",
  "agent diff with unprefixed context applies the intended README text"
)

vim.cmd.edit(tmp .. "/duplicate-diff.md")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "The plugin auto-registers with defaults when it is on `runtimepath`, so no",
  "explicit `setup` call is required. Call `require(\"nvime\").setup({ ... })` only",
  "when you want to override the defaults.",
})
local duplicate_diff_target = vim.api.nvim_get_current_buf()
local duplicate_diff = table.concat({
  "NVIME_DIFF",
  "```diff",
  "--- a/duplicate-diff.md",
  "+++ b/duplicate-diff.md",
  "@@ -1,3 +1,4 @@",
  "-The plugin auto-registers with defaults when it is on `runtimepath`, so no",
  "-explicit `setup` call is required. Call `require(\"nvime\").setup({ ... })` only",
  "-when you want to override the defaults.",
  "+With lazy.nvim, `opts = {}` is enough - lazy will call `setup({})` for you.",
  "+If your manager doesn't do that, nvime still auto-registers with defaults as",
  "+soon as it is on `runtimepath`. Call `require(\"nvime\").setup({ ... })`",
  "+explicitly only to override the defaults.",
  "```NVIME_DIFF",
  "```diff",
  "--- a/duplicate-diff.md",
  "+++ b/duplicate-diff.md",
  "@@ -1,3 +1,4 @@",
  "-The plugin auto-registers with defaults when it is on `runtimepath`, so no",
  "-explicit `setup` call is required. Call `require(\"nvime\").setup({ ... })` only",
  "-when you want to override the defaults.",
  "+With lazy.nvim, `opts = {}` is enough - lazy will call `setup({})` for you.",
  "+If your manager doesn't do that, nvime still auto-registers with defaults as",
  "+soon as it is on `runtimepath`. Call `require(\"nvime\").setup({ ... })`",
  "+explicitly only to override the defaults.",
  "```",
}, "\n")
local duplicate_diff_result = require("nvime.diff").start_session({
  bufnr = duplicate_diff_target,
  line1 = 1,
  line2 = 3,
  path = "duplicate-diff.md",
  source = "test",
}, duplicate_diff, "claude", "")
assert_eq(#duplicate_diff_result.session.hunks, 1, "duplicate NVIME_DIFF blocks collapse to one hunk")
require("nvime.diff").accept_all()
local duplicate_diff_lines = vim.api.nvim_buf_get_lines(duplicate_diff_target, 0, -1, false)
assert_eq(
  table.concat(duplicate_diff_lines, "\n"),
  "With lazy.nvim, `opts = {}` is enough - lazy will call `setup({})` for you.\nIf your manager doesn't do that, nvime still auto-registers with defaults as\nsoon as it is on `runtimepath`. Call `require(\"nvime\").setup({ ... })`\nexplicitly only to override the defaults.",
  "duplicate NVIME_DIFF accept-all applies only proposed content once"
)
assert(not table.concat(duplicate_diff_lines, "\n"):find("%+%+ b/duplicate%-diff%.md"), "diff file header is never applied as content")

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
