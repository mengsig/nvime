local agents = require("nvime.agents")
local buffer_guard = require("nvime.buffer_guard")
local provider_api = require("nvime.provider")
local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local scroll_ns = vim.api.nvim_create_namespace("nvime.chat")
local input_ns = vim.api.nvim_create_namespace("nvime.chat.input")
local focus_group = vim.api.nvim_create_augroup("nvime.chat.focus", { clear = false })

local INPUT_PROMPT_LINE = 1

local function provider()
  return (state.config and state.config.provider) or "claude"
end

local function prompt_prefix()
  return "[" .. provider() .. "]$ "
end

local function chat_config()
  return ((state.config or {}).chat or {})
end

local function status_word()
  if state.chat.busy then
    return "running"
  end
  return "idle"
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

local function with_writable(bufnr, fn, after)
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
  buffer_guard.sync(bufnr, state.panels.chat)
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
  return " nvime  " .. provider() .. "  review/docs  " .. status_word() .. " "
end

local function scroll_config()
  local dim = dimensions()
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
    footer = " i input | <CR> send on prompt | p provider | P choose | q close ",
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
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted"
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

local function decorate_scrollback(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, scroll_ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_code = false
  local code_lang = nil

  local function mark(row, start_col, end_col, group, opts)
    if row < 0 or row >= #lines then
      return
    end
    opts = opts or {}
    opts.end_col = math.min(end_col, #(lines[row + 1] or ""))
    opts.hl_group = group
    vim.api.nvim_buf_set_extmark(bufnr, scroll_ns, row, start_col, opts)
  end

  local function mark_line(row, group)
    if row < 0 or row >= #lines then
      return
    end
    vim.api.nvim_buf_set_extmark(bufnr, scroll_ns, row, 0, {
      end_col = #(lines[row + 1] or ""),
      hl_group = group,
      hl_eol = true,
    })
  end

  for index, line in ipairs(lines) do
    local row = index - 1
    if line:match("^```") then
      mark(row, 0, #line, "NvimeCodeFence")
      if in_code then
        in_code = false
        code_lang = nil
      else
        in_code = true
        code_lang = vim.trim(line:gsub("^```", ""))
      end
    elseif in_code then
      if code_lang == "diff" and line:match("^%+") and not line:match("^%+%+%+") then
        mark_line(row, "NvimeDiffAdd")
      elseif code_lang == "diff" and line:match("^%-") and not line:match("^%-%-%-") then
        mark_line(row, "NvimeDiffDelete")
      elseif code_lang == "diff" and line:match("^@@") then
        mark_line(row, "NvimeDiffHunk")
      else
        mark_line(row, "NvimeCode")
      end
    elseif line:match("^%[[^%]]+%]%$") then
      local finish = line:find("%$") or #line
      mark(row, 0, finish + 1, "NvimePrompt")
      if finish + 1 < #line then
        mark(row, finish + 1, #line, "NvimeUserText")
      end
    elseif line:match("^%[[^%]]+ response%]$") then
      mark(row, 0, #line, "NvimeAgent")
    elseif line:match("^%[nvime%]") then
      mark(row, 0, #line, "NvimeExit")
    elseif line:match("^%[error%]") or line:match("^%[failed%]") then
      mark(row, 0, #line, "NvimeError")
    elseif line:match("^#+%s+") then
      mark(row, 0, #line, "NvimeMarkdownHeading")
    elseif line:match("^%s*[-*]%s+") then
      local start_col = line:find("[-*]")
      if start_col then
        mark(row, start_col - 1, start_col + 1, "NvimeBullet")
      end
    elseif line:match("^%s*>%s+") then
      mark(row, 0, #line, "NvimeQuote")
    elseif line:match("^@@") then
      mark_line(row, "NvimeDiffHunk")
    elseif line:match("^%+") and not line:match("^%+%+%+") then
      mark_line(row, "NvimeDiffAdd")
    elseif line:match("^%-") and not line:match("^%-%-%-") and not line:match("^%-%-+$") then
      mark_line(row, "NvimeDiffDelete")
    elseif line:match("^[=-]+$") then
      mark(row, 0, #line, "NvimeRule")
    end

    local search_from = 1
    while true do
      local strong_start, strong_end = line:find("%*%*.-%*%*", search_from)
      if not strong_start then
        break
      end
      mark(row, strong_start - 1, strong_end, "NvimeMarkdownStrong")
      search_from = strong_end + 1
    end
  end
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
  end
end

local function scroll_to_bottom()
  local panel = state.panels.chat
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return
  end
  local target = math.max(1, (panel.input_start or line_count(panel.bufnr)))
  vim.api.nvim_win_set_cursor(panel.winid, { target, 0 })
end

local function refresh_header(bufnr)
  decorate_scrollback(bufnr)
end

local function reset_input(text)
  local panel = state.panels.chat
  local bufnr = panel and panel.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  text = text or ""
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
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    local prompt_lnum = panel.input_start + INPUT_PROMPT_LINE - 1
    pcall(vim.api.nvim_win_set_cursor, panel.winid, { prompt_lnum, #prompt_prefix() })
    pcall(vim.api.nvim_win_call, panel.winid, function()
      vim.fn.winrestview({ topline = math.max(1, prompt_lnum - vim.api.nvim_win_get_height(panel.winid) + 2) })
    end)
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
    if in_input_window(state.panels.chat) then
      require("nvime.chat").submit_current()
    else
      require("nvime.chat").prompt()
    end
  end, opts)
  vim.keymap.set("n", "i", function()
    require("nvime.chat").prompt()
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
  vim.keymap.set("i", "<CR>", function()
    vim.cmd.stopinsert()
    require("nvime.chat").submit_current()
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

  local panel = state.panels.chat or {}
  if panel.input_winid and panel.input_winid ~= panel.winid and vim.api.nvim_win_is_valid(panel.input_winid) then
    pcall(vim.api.nvim_win_close, panel.input_winid, true)
  end
  local scroll_buf = panel.bufnr
  if not scroll_buf or not vim.api.nvim_buf_is_valid(scroll_buf) then
    scroll_buf = ensure_named_buffer("nvime://chat", "nvime")
  else
    set_scratch_options(scroll_buf, "nvime")
  end

  local scroll_win = open_or_configure_window(scroll_buf, panel.winid, scroll_config(), configure_scrollback_window, true)

  state.panels.chat = {
    bufnr = scroll_buf,
    winid = scroll_win,
    input_bufnr = scroll_buf,
    input_winid = scroll_win,
    input_start = panel.input_start,
    input_active = panel.input_active == true,
  }

  attach_panel(scroll_buf)
  attach_focus_lock(scroll_buf)
  attach_input_guard(scroll_buf)
  refresh_header(scroll_buf)
  reset_input(current_input_text())
  set_locked(scroll_buf, true)
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
    set_locked(bufnr, true)
  end
  refresh_input()
end

local function append_scrollback(text)
  if not text or text == "" then
    return
  end

  local panel = state.panels.chat
  local bufnr = panel and panel.bufnr
  if not bufnr then
    return
  end

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
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
      end
    end, decorate_scrollback)
    set_locked(bufnr, true)
    scroll_to_bottom()
  end)
end

local function append_user_message(bufnr, text)
  local panel = state.panels.chat
  with_writable(bufnr, function()
    local insert_at = math.max(0, (panel.input_start or (line_count(bufnr) + 1)) - 1)
    local lines = {
      "",
      prompt_prefix() .. text,
    }
    vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, lines)
    panel.input_start = insert_at + #lines + 1
  end, decorate_scrollback)
  set_locked(bufnr, true)
  scroll_to_bottom()
end

local function append_response_header(bufnr)
  local panel = state.panels.chat
  with_writable(bufnr, function()
    local insert_at = math.max(0, (panel.input_start or (line_count(bufnr) + 1)) - 1)
    local lines = {
      "",
      "[" .. provider() .. " response]",
      "",
    }
    vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, lines)
    panel.input_start = insert_at + #lines + 1
  end, decorate_scrollback)
  set_locked(bufnr, true)
  scroll_to_bottom()
end

local function trim_history()
  local max = chat_config().max_history_messages or 24
  while #state.chat.history > max do
    table.remove(state.chat.history, 1)
  end
end

local function build_conversation_prompt(text)
  local markdown_policy = "Markdown writes are disabled in this lane."
  if ((state.config or {}).review or {}).allow_markdown_writes == true then
    markdown_policy =
      "You may create or update Markdown documentation files only (*.md, *.markdown). Do not edit source/config files directly."
  end
  local shell_policy = "Shell commands are disabled."
  if ((state.config or {}).review or {}).allow_shell == true then
    shell_policy = "You may run shell commands for inspection and tests."
  end

  local lines = {
    "NVIME CHAT MODE.",
    "You are the side agent inside Neovim.",
    "You may answer questions, review code, and suggest changes.",
    markdown_policy,
    shell_policy,
    "Never edit non-Markdown files from this lane. Source changes must go through NVIME EDIT MODE and reviewed diffs.",
    "Continue the conversation using the transcript below.",
    "",
    "Conversation so far:",
  }

  if #state.chat.history == 0 then
    lines[#lines + 1] = "(empty)"
  else
    for _, message in ipairs(state.chat.history) do
      lines[#lines + 1] = string.upper(message.role) .. ": " .. message.content
    end
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "USER: " .. text
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Answer the latest user message with the prior conversation in mind."
  return table.concat(lines, "\n")
end

function M.set_busy(value)
  state.chat.busy = value == true
  M.refresh()
end

function M.append(text)
  M.open()
  append_scrollback(text)
end

function M.append_user(text)
  local bufnr = M.open()
  append_user_message(bufnr, text)
end

function M.append_response_header()
  local bufnr = M.open()
  append_response_header(bufnr)
end

function M.submit(text, opts)
  opts = opts or {}
  local bufnr = M.open()
  text = vim.trim(text or "")
  if text == "" then
    reset_input("")
    return
  end

  state.chat.busy = true
  M.refresh(bufnr)

  if opts.display_user ~= false then
    append_user_message(bufnr, text)
  end
  append_response_header(bufnr)

  local prompt = build_conversation_prompt(text)
  state.chat.history[#state.chat.history + 1] = {
    role = "user",
    content = text,
  }
  trim_history()

  local response = {}
  agents.run({
    provider = provider(),
    lane = "review",
    prompt = prompt,
    on_text = function(chunk)
      response[#response + 1] = chunk
      append_scrollback(chunk)
    end,
    on_progress = function(chunk)
      append_scrollback(chunk)
    end,
    on_exit = function(result)
      local assistant_text = vim.trim(table.concat(response))
      if assistant_text ~= "" then
        state.chat.history[#state.chat.history + 1] = {
          role = "assistant",
          content = assistant_text,
        }
        trim_history()
      end
      state.chat.busy = false
      local synced = result.nvime_synced_markdown or {}
      if #synced > 0 then
        vim.notify("nvime synced markdown: " .. table.concat(synced, ", "), vim.log.levels.INFO)
      end
      if result.code ~= 0 then
        append_scrollback("\n[nvime] chat failed with code " .. tostring(result.code) .. "\n")
      end
      vim.schedule(function()
        M.refresh(bufnr)
      end)
    end,
  })
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
  local append = opts.cursor == "end"
  local end_col = prompt_end_col(panel)
  local empty_prompt = end_col <= #prompt_prefix()
  local col = (append or empty_prompt) and math.max(0, end_col - 1) or #prompt_prefix()
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

return M
