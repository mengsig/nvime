local chat = require("nvime.chat")
local selection = require("nvime.selection")
local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local ns = vim.api.nvim_create_namespace("nvime.chats")
local backdrop_ns = vim.api.nvim_create_namespace("nvime.chats.backdrop")

local DASHBOARD_TABS = {
  { id = "all", label = "All" },
  { id = "chat", label = "Chat" },
  { id = "ask", label = "Ask" },
  { id = "edit", label = "Edit" },
  { id = "running", label = "Running" },
}

local DASHBOARD_TAB_BY_INDEX = {}
for index, tab in ipairs(DASHBOARD_TABS) do
  DASHBOARD_TAB_BY_INDEX[index] = tab.id
end

local function find_buffer_by_name(name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      return bufnr
    end
  end
  return nil
end

local function ensure_buffer()
  local bufnr = find_buffer_by_name("nvime://chats")
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "nvime://chats")
  end
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "nvime"
  return bufnr
end

local function set_locked(bufnr, locked)
  vim.bo[bufnr].readonly = locked
  vim.bo[bufnr].modifiable = not locked
end

local function dimensions(mode)
  local cfg = (state.config or {}).ui or {}
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = math.floor(columns * (cfg.float_width or 0.78))
  local default_height = mode == "dashboard" and 0.86 or 0.56
  local height = math.floor(lines * default_height)
  if cfg.width and type(cfg.width) == "number" and not (type(cfg.float_width) == "number" and cfg.float_width > 0) then
    width = math.max(64, math.min(cfg.width, columns - 6))
  end
  if type(cfg.float_width) == "number" and cfg.float_width > 0 and cfg.float_width <= 1 then
    width = math.floor(columns * cfg.float_width)
  end
  if mode == "dashboard" and type(cfg.dashboard_width) == "number" and cfg.dashboard_width > 0 and cfg.dashboard_width <= 1 then
    width = math.floor(columns * cfg.dashboard_width)
  elseif mode == "dashboard" then
    width = math.floor(columns * math.max(type(cfg.float_width) == "number" and cfg.float_width or 0, 0.86))
  end
  if type(cfg.float_height) == "number" and cfg.float_height > 0 and cfg.float_height <= 1 then
    local height_ratio = cfg.float_height
    if mode == "dashboard" then
      height_ratio = cfg.dashboard_height or math.max(height_ratio, 0.84)
    else
      height_ratio = math.min(height_ratio, 0.7)
    end
    height = math.floor(lines * height_ratio)
  end
  if mode == "dashboard" and type(cfg.dashboard_height) == "number" and cfg.dashboard_height > 0 and cfg.dashboard_height <= 1 then
    height = math.floor(lines * cfg.dashboard_height)
  end
  local max_width = mode == "dashboard" and columns - 2 or columns - 6
  local max_height = mode == "dashboard" and lines - 2 or lines - 6
  width = math.max(64, math.min(width, max_width))
  height = math.max(12, math.min(height, max_height))
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2 - 1)),
    col = math.max(0, math.floor((columns - width) / 2)),
    border = cfg.border or "rounded",
  }
end

local function window_config(mode)
  local panel = state.panels.chats or {}
  mode = mode or (panel.mode == "dashboard" and "dashboard" or panel.mode)
  local dim = dimensions(mode)
  local footer = " 1-9 open | <CR> open | n new | dd delete | r refresh | ? help | q close "
  if mode == "dashboard" then
    footer = " (1)-(5) tabs | <CR> open | n new | a ask | e edit | dd delete | r refresh | ? help | q close "
  end
  return {
    relative = "editor",
    width = dim.width,
    height = dim.height,
    row = dim.row,
    col = dim.col,
    style = "minimal",
    border = dim.border,
    title = mode == "dashboard" and " nvime.nvim " or " nvime command center ",
    title_pos = "center",
    footer = footer,
    footer_pos = "center",
    zindex = 54,
  }
end

local function configure_window(winid)
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].cursorline = true
  vim.wo[winid].spell = false
  vim.wo[winid].winblend = 0
  vim.wo[winid].winhighlight =
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted,CursorLine:NvimeCursorLine"
end

local function close_backdrop()
  local backdrop = state.panels.chats_backdrop
  if backdrop and backdrop.winid and vim.api.nvim_win_is_valid(backdrop.winid) then
    pcall(vim.api.nvim_win_close, backdrop.winid, true)
  end
  state.panels.chats_backdrop = nil
end

local function open_backdrop()
  local cfg = (state.config or {}).ui or {}
  if cfg.backdrop == false then
    close_backdrop()
    return
  end
  local existing = state.panels.chats_backdrop
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  local height = math.max(1, vim.o.lines - 1)
  local width = math.max(1, vim.o.columns)
  local blank_lines = {}
  for _ = 1, height do
    blank_lines[#blank_lines + 1] = string.rep(" ", width)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, blank_lines)
  vim.api.nvim_buf_clear_namespace(bufnr, backdrop_ns, 0, -1)
  for row = 0, height - 1 do
    vim.api.nvim_buf_set_extmark(bufnr, backdrop_ns, row, 0, {
      end_col = width,
      hl_group = "NvimeBackdrop",
    })
  end
  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, false, {
    relative = "editor",
    width = width,
    height = height,
    row = 0,
    col = 0,
    style = "minimal",
    focusable = false,
    zindex = 50,
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end
  vim.wo[winid].winblend = tonumber(cfg.backdrop) or 60
  vim.wo[winid].winhighlight = "NormalFloat:NvimeBackdrop"
  state.panels.chats_backdrop = {
    bufnr = bufnr,
    winid = winid,
  }
end

local function close()
  local help = state.panels.chats_help
  if help and help.winid and vim.api.nvim_win_is_valid(help.winid) then
    pcall(vim.api.nvim_win_close, help.winid, true)
  end
  state.panels.chats_help = nil
  local panel = state.panels.chats
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_close, panel.winid, true)
  end
  close_backdrop()
end

local function open_help()
  local panel = state.panels.chats
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return
  end
  if panel.mode == "dashboard" then
    local show_help = not panel.show_help
    state.panels.chats_help = show_help and {
      bufnr = panel.bufnr,
      winid = panel.winid,
      in_buffer = true,
    } or nil
    M.open({
      mode = "dashboard",
      tab = panel.tab,
      show_help = show_help,
    })
    return
  end
  local existing = state.panels.chats_help
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    pcall(vim.api.nvim_win_close, existing.winid, true)
    state.panels.chats_help = nil
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "nvime"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "nvime controls",
    "",
    "  <CR> / o / i   open selected row",
    "  1-9            open numbered row",
    "  n              start a fresh session",
    "  e              start an edit discussion",
    "  dd             delete selected row",
    "  V ... d        delete selected rows",
    "  r              refresh this console",
    "  q / <Esc>      close",
    "",
    "Rows show status, provider, native resume state, age, and title/context.",
  })
  local width = math.min(58, math.max(42, vim.api.nvim_win_get_width(panel.winid) - 8))
  local height = 13
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "win",
    win = panel.winid,
    width = width,
    height = height,
    row = 2,
    col = math.max(1, vim.api.nvim_win_get_width(panel.winid) - width - 4),
    style = "minimal",
    border = ((state.config or {}).ui or {}).border or "rounded",
    title = " help ",
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].winhighlight =
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle"
  local first_line = vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
    end_col = #first_line,
    hl_group = "NvimeHeader",
  })
  for row = 2, 9 do
    local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
    local gap_start = line:find("  ", 3, true)
    local key_end = gap_start and gap_start - 1 or math.min(15, #line)
    if key_end > 2 then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, 2, {
        end_col = key_end,
        hl_group = "NvimeKey",
      })
    end
  end
  local opts = { buffer = bufnr, silent = true }
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
    state.panels.chats_help = nil
  end, opts)
  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(winid) then
      pcall(vim.api.nvim_win_close, winid, true)
    end
    state.panels.chats_help = nil
  end, opts)
  state.panels.chats_help = {
    bufnr = bufnr,
    winid = winid,
  }
end

local function format_range(session)
  local selected = session.selection or {}
  local path = selected.path or "(unknown)"
  return string.format("%s:%s-%s", ui.truncate(path, 34), tostring(selected.line1 or "?"), tostring(selected.line2 or "?"))
end

local function native_text(session, provider_name)
  if session.provider_sessions and session.provider_sessions[provider_name] then
    return ui.icon("resume") .. " resume"
  end
  return ui.icon("local_session") .. " local"
end

local function requested_mode()
  local panel = state.panels.chats or {}
  if panel.mode == "ask" or panel.mode == "edit" or panel.mode == "chat" or panel.mode == "dashboard" then
    return panel.mode
  end
  return nil
end

local function is_chat_mode()
  return requested_mode() == "chat"
end

local function is_dashboard()
  return requested_mode() == "dashboard"
end

local function count_running(sessions)
  local count = 0
  for _, session in ipairs(sessions or {}) do
    if session.busy then
      count = count + 1
    end
  end
  return count
end

local function count_all_running(chat_sessions, selection_sessions)
  return count_running(chat_sessions) + count_running(selection_sessions)
end

local function render_width()
  local panel = state.panels.chats or {}
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    return vim.api.nvim_win_get_width(panel.winid)
  end
  return dimensions(requested_mode()).width
end

local function add_mark(marks, row, start_col, end_col, hl_group)
  if end_col <= start_col then
    return
  end
  marks[#marks + 1] = {
    row = row,
    start_col = start_col,
    end_col = end_col,
    hl_group = hl_group,
  }
end

local function centered_prefix(text, width)
  return string.rep(" ", math.max(0, math.floor((width - #text) / 2)))
end

local function add_centered_blocks(lines, marks, parts, width)
  local text = ""
  for _, part in ipairs(parts) do
    text = text .. part[1]
  end
  local prefix = centered_prefix(text, width)
  local row = #lines + 1
  lines[row] = prefix .. text
  local offset = #prefix
  for _, part in ipairs(parts) do
    local value = part[1]
    add_mark(marks, row, offset, offset + #value, part[2])
    offset = offset + #value
  end
  return row
end

local function add_centered_text(lines, marks, text, width, hl_group)
  local row = #lines + 1
  local prefix = centered_prefix(text, width)
  lines[row] = prefix .. text
  if hl_group then
    add_mark(marks, row, #prefix, #prefix + #text, hl_group)
  end
  return row
end

local function dashboard_tab()
  local panel = state.panels.chats or {}
  return panel.tab or "all"
end

local function add_branded_header(lines, marks, subtitle)
  local width = render_width()
  add_centered_blocks(lines, marks, {
    { " nvime.nvim ", "NvimeHeaderBlock" },
    { " v0.1.0 ", "NvimeHeaderBlockSecondary" },
  }, width)
  add_centered_blocks(lines, marks, {
    { "press ", "NvimeMuted" },
    { " ? ", "NvimeKey" },
    { " for help", "NvimeMuted" },
  }, width)
  if subtitle and subtitle ~= "" then
    add_centered_text(lines, marks, subtitle, width, "NvimeMuted")
  end
end

local function add_dashboard_tabs(lines, marks)
  local active = dashboard_tab()
  local row = #lines + 1
  local line = "  "
  local offset = #line
  lines[row] = line
  for index, tab in ipairs(DASHBOARD_TABS) do
    local label = string.format("(%d) %s", index, tab.label)
    lines[row] = lines[row] .. label .. "    "
    add_mark(marks, row, offset, offset + #label, tab.id == active and "NvimeTabActive" or "NvimeTabInactive")
    offset = offset + #label + 4
  end
  return row
end

local function add_count_mark(count_marks, row, count)
  count_marks[#count_marks + 1] = {
    row = row,
    text = " (" .. tostring(count) .. ")",
  }
end

local function session_mode(session, kind)
  if kind == "chat" then
    return "chat"
  end
  return session.mode or "selection"
end

local function session_title(session, kind)
  if kind == "chat" then
    return session.title or ("Chat #" .. tostring(session.id or "?"))
  end
  return format_range(session)
end

local function provider_label(session)
  return session.provider or "?"
end

local function session_primary_line(session, kind, index)
  local status_icon = session.busy and ui.icon("active") or ui.icon("idle")
  local title = session_title(session, kind)
  local provider = provider_label(session)
  local suffix = string.format("%s  %s  %s", provider, session_mode(session, kind), ui.relative_time(session.updated_at))
  local max_title = math.max(24, render_width() - #suffix - 12)
  if index and index <= 9 then
    return string.format(" %d  %s %s  %s", index, status_icon, ui.truncate(title, max_title), suffix)
  end
  return string.format("  %s %s  %s", status_icon, ui.truncate(title, max_title), suffix)
end

local function session_detail_line(session, kind)
  local provider = provider_label(session)
  local detail = {
    native_text(session, provider),
  }
  if kind == "selection" then
    local selected = session.selection or {}
    detail[#detail + 1] = (selected.source or "range")
    detail[#detail + 1] = session.mode or "selection"
  else
    detail[#detail + 1] = "review/docs"
  end
  if session.busy and session.progress then
    detail[#detail + 1] = require("nvime.render").spinner_text() .. " " .. session.progress
  end
  if session.provider_sessions and session.provider_sessions[provider] then
    detail[#detail + 1] = "native " .. ui.truncate(session.provider_sessions[provider], 24)
  end
  return "     " .. table.concat(detail, "  ")
end

local function include_dashboard_session(tab, session, kind)
  if tab == "all" then
    return true
  end
  if tab == "running" then
    return session.busy == true
  end
  if tab == "chat" then
    return kind == "chat"
  end
  if tab == "ask" or tab == "edit" then
    return kind == "selection" and (session.mode or "selection") == tab
  end
  return true
end

local function add_dashboard_rows(lines, row_to_session, row_to_kind, number_to_row, detail_rows, sessions, kind, limit, opts)
  opts = opts or {}
  local added = 0
  for _, session in ipairs(sessions) do
    if added >= limit then
      break
    end
    local row = #lines + 1
    row_to_session[row] = session.id
    row_to_kind[row] = kind
    number_to_row[#number_to_row + 1] = row
    local index = opts.show_numbers and #number_to_row or nil
    lines[row] = session_primary_line(session, kind, index)
    detail_rows[#lines + 1] = true
    lines[#lines + 1] = session_detail_line(session, kind)
    added = added + 1
  end
  return added
end

local function filtered_dashboard_sessions(tab, chat_sessions, selection_sessions)
  local filtered_chats = {}
  local filtered_selections = {}
  for _, session in ipairs(chat_sessions) do
    if include_dashboard_session(tab, session, "chat") then
      filtered_chats[#filtered_chats + 1] = session
    end
  end
  for _, session in ipairs(selection_sessions) do
    if include_dashboard_session(tab, session, "selection") then
      filtered_selections[#filtered_selections + 1] = session
    end
  end
  return filtered_chats, filtered_selections
end

local function add_dashboard_help(lines, section_rows, meta_rows)
  lines[#lines + 1] = "Keymaps"
  section_rows[#section_rows + 1] = #lines
  lines[#lines + 1] = "  g? / ?         toggle this help"
  meta_rows[#meta_rows + 1] = #lines
  lines[#lines + 1] = "  (1)-(5)        switch All, Chat, Ask, Edit, Running tabs"
  meta_rows[#meta_rows + 1] = #lines
  lines[#lines + 1] = "  <CR> / o / i   open the selected session or action"
  meta_rows[#meta_rows + 1] = #lines
  lines[#lines + 1] = "  n / a / e      start chat, Ask, or Edit from the current context"
  meta_rows[#meta_rows + 1] = #lines
  lines[#lines + 1] = "  dd / V...d     delete one session or a visual range"
  meta_rows[#meta_rows + 1] = #lines
  lines[#lines + 1] = "  r              refresh package/session state"
  meta_rows[#meta_rows + 1] = #lines
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Panels"
  section_rows[#section_rows + 1] = #lines
  lines[#lines + 1] = "  Chat rows are long-running review/docs conversations."
  meta_rows[#meta_rows + 1] = #lines
  lines[#lines + 1] = "  Ask/Edit rows are scoped to a file range and keep their native provider session when possible."
  meta_rows[#meta_rows + 1] = #lines
end

local function render(bufnr)
  local mode = requested_mode()
  local lines = {}
  local row_to_session = {}
  local row_to_kind = {}
  local row_to_action = {}
  local number_to_row = {}
  local section_rows = {}
  local meta_rows = {}
  local action_rows = {}
  local detail_rows = {}
  local span_marks = {}
  local count_marks = {}

  if mode == "dashboard" then
    local chat_sessions = chat.sessions()
    local selection_sessions = selection.sessions()
    local tab = dashboard_tab()
    local filtered_chats, filtered_selections = filtered_dashboard_sessions(tab, chat_sessions, selection_sessions)
    add_branded_header(lines, span_marks, "review/docs chat  |  scoped ask  |  reviewed edit")
    lines[#lines + 1] = ""
    add_dashboard_tabs(lines, span_marks)
    lines[#lines + 1] = ""
    local provider = (state.config and state.config.provider) or "claude"
    lines[#lines + 1] = string.format(
      "Workflow Filter: %s %d chats   %s %d scoped   %s %d running   %s provider %s",
      ui.icon("chat"),
      #chat_sessions,
      ui.icon("selection"),
      #selection_sessions,
      ui.icon("active"),
      count_all_running(chat_sessions, selection_sessions),
      ui.icon("review"),
      provider
    )
    meta_rows[#meta_rows + 1] = #lines
    lines[#lines + 1] = ""

    if state.panels.chats and state.panels.chats.show_help then
      add_dashboard_help(lines, section_rows, meta_rows)
    else
      lines[#lines + 1] = "Actions"
      section_rows[#section_rows + 1] = #lines
      row_to_action[#lines + 1] = { type = "new_chat" }
      action_rows[#lines + 1] = true
      lines[#lines + 1] = " n  new review/docs chat"
      row_to_action[#lines + 1] = { type = "new", mode = "ask" }
      action_rows[#lines + 1] = true
      lines[#lines + 1] = " a  ask about current function"
      row_to_action[#lines + 1] = { type = "new", mode = "edit" }
      action_rows[#lines + 1] = true
      lines[#lines + 1] = " e  edit current function"
      lines[#lines + 1] = ""

      if #filtered_chats > 0 then
        lines[#lines + 1] = "General Conversations"
        section_rows[#section_rows + 1] = #lines
        add_count_mark(count_marks, #lines, #filtered_chats)
        add_dashboard_rows(lines, row_to_session, row_to_kind, number_to_row, detail_rows, filtered_chats, "chat", 20)
        lines[#lines + 1] = ""
      end

      if #filtered_selections > 0 then
        lines[#lines + 1] = "Selection Discussions"
        section_rows[#section_rows + 1] = #lines
        add_count_mark(count_marks, #lines, #filtered_selections)
        add_dashboard_rows(
          lines,
          row_to_session,
          row_to_kind,
          number_to_row,
          detail_rows,
          filtered_selections,
          "selection",
          24
        )
      end

      if #filtered_chats == 0 and #filtered_selections == 0 then
        lines[#lines + 1] = "No saved nvime sessions match this tab."
        meta_rows[#meta_rows + 1] = #lines
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Press n for review/docs chat, or open a file and use a/e for scoped work."
        meta_rows[#meta_rows + 1] = #lines
      end
    end
  elseif mode == "chat" then
    local sessions = chat.sessions()
    add_branded_header(lines, span_marks, "review/docs chat lane")
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "Status: %s %d saved   %s %d running   %s provider %s",
      ui.icon("chat"),
      #sessions,
      ui.icon("active"),
      count_running(sessions),
      ui.icon("review"),
      (state.config and state.config.provider) or "claude"
    )
    meta_rows[#meta_rows + 1] = #lines
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Actions"
    section_rows[#section_rows + 1] = #lines
    row_to_action[#lines + 1] = { type = "new_chat" }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " n  start new chat conversation"
    lines[#lines + 1] = ""

    if #sessions == 0 then
      lines[#lines + 1] = "General Conversations"
      section_rows[#section_rows + 1] = #lines
      lines[#lines + 1] = "  No general chat conversations yet."
      meta_rows[#meta_rows + 1] = #lines
      lines[#lines + 1] = "  Press n to start one, or <CR> on the new row."
      meta_rows[#meta_rows + 1] = #lines
    else
      lines[#lines + 1] = "General Conversations"
      section_rows[#section_rows + 1] = #lines
      add_count_mark(count_marks, #lines, #sessions)
      add_dashboard_rows(lines, row_to_session, row_to_kind, number_to_row, detail_rows, sessions, "chat", 20, { show_numbers = true })
    end
  elseif mode then
    local sessions = selection.sessions()
    add_branded_header(lines, span_marks, "scoped " .. mode .. " lane")
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "Status: %s %d saved   %s %d running   %s lane %s",
      ui.icon("selection"),
      #sessions,
      ui.icon("active"),
      count_running(sessions),
      ui.icon(mode),
      mode
    )
    meta_rows[#meta_rows + 1] = #lines
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Actions"
    section_rows[#section_rows + 1] = #lines
    row_to_action[#lines + 1] = { type = "new", mode = mode }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " n  start new " .. mode .. " session from current function"
    lines[#lines + 1] = ""

    if #sessions == 0 then
      lines[#lines + 1] = "Selection Discussions"
      section_rows[#section_rows + 1] = #lines
      lines[#lines + 1] = "  No highlighted-code discussions yet."
      meta_rows[#meta_rows + 1] = #lines
      lines[#lines + 1] = "  Select code and press visual <leader>nq or visual <leader>ne, or start from the current function above."
      meta_rows[#meta_rows + 1] = #lines
    else
      lines[#lines + 1] = "Selection Discussions"
      section_rows[#section_rows + 1] = #lines
      add_count_mark(count_marks, #lines, #sessions)
      add_dashboard_rows(lines, row_to_session, row_to_kind, number_to_row, detail_rows, sessions, "selection", 24, { show_numbers = true })
    end
  else
    local sessions = selection.sessions()
    add_branded_header(lines, span_marks, "ask + edit + diff follow-up")
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "Status: %s %d saved   %s %d running   %s choose ask/edit",
      ui.icon("selection"),
      #sessions,
      ui.icon("active"),
      count_running(sessions),
      ui.icon("key")
    )
    meta_rows[#meta_rows + 1] = #lines
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Actions"
    section_rows[#section_rows + 1] = #lines
    row_to_action[#lines + 1] = { type = "new", mode = "ask" }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " n  start new ask session from current function"
    row_to_action[#lines + 1] = { type = "new", mode = "edit" }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " e  start new edit session from current function"
    lines[#lines + 1] = ""

    if #sessions == 0 then
      lines[#lines + 1] = "Selection Discussions"
      section_rows[#section_rows + 1] = #lines
      lines[#lines + 1] = "  No highlighted-code discussions yet."
      meta_rows[#meta_rows + 1] = #lines
      lines[#lines + 1] = "  Select code and press visual <leader>nq or visual <leader>ne, or start from the current function above."
      meta_rows[#meta_rows + 1] = #lines
    else
      lines[#lines + 1] = "Selection Discussions"
      section_rows[#section_rows + 1] = #lines
      add_count_mark(count_marks, #lines, #sessions)
      add_dashboard_rows(lines, row_to_session, row_to_kind, number_to_row, detail_rows, sessions, "selection", 24, { show_numbers = true })
    end
  end

  set_locked(bufnr, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  set_locked(bufnr, true)

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, mark in ipairs(span_marks) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, mark.row - 1, mark.start_col, {
      end_col = mark.end_col,
      hl_group = mark.hl_group,
    })
  end
  for _, row in ipairs(section_rows) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      end_col = #(lines[row] or ""),
      hl_group = row == 1 and "NvimeHeader" or "NvimeSection",
    })
  end
  for _, mark in ipairs(count_marks) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, mark.row - 1, #(lines[mark.row] or ""), {
      virt_text = { { mark.text, "NvimeMuted" } },
      virt_text_pos = "eol",
    })
  end
  for _, row in ipairs(meta_rows) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      end_col = #(lines[row] or ""),
      hl_group = "NvimeMuted",
    })
  end
  for row, _ in pairs(detail_rows) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      end_col = #(lines[row] or ""),
      hl_group = "NvimeRowDetail",
    })
  end
  for row, _ in pairs(action_rows) do
    local line = lines[row] or ""
    local key_start, key_end = line:find("^%s+(%S+)")
    if key_start and key_end then
      local key_first_col = line:find("%S")
      vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, key_first_col - 1, {
        end_col = key_end,
        hl_group = "NvimeKey",
      })
      vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, key_end, {
        end_col = #line,
        hl_group = "NvimeUserText",
      })
    end
  end
  for row, session_id in pairs(row_to_session) do
    local kind = row_to_kind[row] or (is_chat_mode() and "chat" or "selection")
    local session = kind == "chat" and chat.get_session(session_id) or selection.get_session(session_id)
    local line = lines[row] or ""
    if mode == "dashboard" then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 2, {
        end_col = math.min(3, #line),
        hl_group = session and session.busy and "NvimeStatusRunning" or "NvimeStatusIdle",
      })
      vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 4, {
        end_col = math.max(4, math.min(#line, render_width() - 24)),
        hl_group = "NvimeRowTitle",
      })
    else
      vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
        end_col = math.min(2, #line),
        hl_group = "NvimeRowIndex",
      })
    end
    local provider = session and session.provider
    if provider then
      local start_col = line:find(provider, 1, true)
      if start_col then
        vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, start_col - 1, {
          end_col = start_col - 1 + #provider,
          hl_group = provider == "claude" and "NvimeProviderClaude" or "NvimeProviderCodex",
        })
      end
    end
    local status_word = session and session.busy and "running" or "idle"
    local status_start = line:find(status_word, 1, true)
    if status_start then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, status_start - 1, {
        end_col = math.min(#line, status_start - 1 + #status_word),
        hl_group = session and session.busy and "NvimeStatusRunning" or "NvimeStatusIdle",
      })
    end
    if session and session.busy then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
        line_hl_group = "NvimeDiffHunk",
      })
    end
  end

  state.panels.chats.row_to_session = row_to_session
  state.panels.chats.row_to_kind = row_to_kind
  state.panels.chats.row_to_action = row_to_action
  state.panels.chats.number_to_row = number_to_row
end

local function selected_item()
  local panel = state.panels.chats
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(panel.winid)[1]
  if panel.row_to_action and panel.row_to_action[row] then
    return panel.row_to_action[row]
  end
  local session_id = panel.row_to_session and panel.row_to_session[row]
  if session_id then
    local kind = panel.row_to_kind and panel.row_to_kind[row]
    return {
      type = (kind == "chat" or is_chat_mode()) and "chat_session" or "session",
      session_id = session_id,
    }
  end
  return nil
end

local function selected_session_refs()
  local panel = state.panels.chats
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return {}
  end

  local first = vim.api.nvim_win_get_cursor(panel.winid)[1]
  local last = first
  local current_mode = vim.fn.mode()
  if current_mode == "v" or current_mode == "V" or current_mode == "\22" then
    local anchor = vim.fn.getpos("v")[2]
    if anchor and anchor > 0 then
      first = math.min(anchor, last)
      last = math.max(anchor, last)
    end
    vim.cmd.normal({ args = { "\27" }, bang = true })
  end

  local refs = {}
  local seen = {}
  for row = first, last do
    local session_id = panel.row_to_session and panel.row_to_session[row]
    local kind = panel.row_to_kind and panel.row_to_kind[row] or (is_chat_mode() and "chat" or "selection")
    local key = tostring(kind) .. ":" .. tostring(session_id)
    if session_id and not seen[key] then
      seen[key] = true
      refs[#refs + 1] = {
        id = session_id,
        kind = kind,
      }
    end
  end
  return refs
end

local function open_selected()
  local item = selected_item()
  if not item then
    return
  end
  close()
  if item.type == "new_chat" then
    chat.new_session()
  elseif item.type == "new" then
    require("nvime." .. item.mode).start({
      new_session = true,
    })
  elseif item.type == "chat_session" then
    chat.open_session(item.session_id)
  elseif item.type == "session" then
    local mode = requested_mode()
    local session = selection.get_session(item.session_id)
    if session and (mode == "ask" or mode == "edit") then
      require("nvime." .. mode).start({
        selection = session.selection,
        session_id = item.session_id,
      })
    else
      selection.open_session(item.session_id)
    end
  end
end

local function open_number(index)
  local panel = state.panels.chats
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return
  end
  local row = panel.number_to_row and panel.number_to_row[index]
  if not row then
    vim.notify("No nvime session at number " .. tostring(index), vim.log.levels.INFO)
    return
  end
  vim.api.nvim_win_set_cursor(panel.winid, { row, 0 })
  open_selected()
end

local function open_new(mode)
  close()
  if mode == "chat" then
    chat.new_session()
    return
  end
  require("nvime." .. mode).start({
    new_session = true,
  })
end

local function delete_selected()
  local refs = selected_session_refs()
  if #refs == 0 then
    vim.notify("No nvime " .. (is_chat_mode() and "chat" or "discussion") .. " selected", vim.log.levels.INFO)
    return
  end
  local chat_ids = {}
  local selection_ids = {}
  for _, ref in ipairs(refs) do
    if ref.kind == "chat" then
      chat_ids[#chat_ids + 1] = ref.id
    else
      selection_ids[#selection_ids + 1] = ref.id
    end
  end
  local deleted = chat.delete_sessions(chat_ids) + selection.delete_sessions(selection_ids)
  if deleted > 0 then
    vim.notify("Deleted " .. tostring(deleted) .. " nvime session(s)", vim.log.levels.INFO)
  end
  M.open({ mode = requested_mode() })
end

local function attach_maps(bufnr)
  local opts = { buffer = bufnr, silent = true }
  vim.keymap.set("n", "<CR>", open_selected, opts)
  vim.keymap.set("n", "o", open_selected, opts)
  vim.keymap.set("n", "i", open_selected, opts)
  vim.keymap.set("n", "n", function()
    local mode = requested_mode()
    open_new(mode == "dashboard" and "chat" or mode or "ask")
  end, opts)
  vim.keymap.set("n", "e", function()
    if is_chat_mode() then
      open_selected()
      return
    end
    open_new("edit")
  end, opts)
  vim.keymap.set("n", "a", function()
    if is_dashboard() then
      open_new("ask")
    else
      open_selected()
    end
  end, opts)
  vim.keymap.set("n", "r", function()
    M.open({ mode = requested_mode() })
  end, opts)
  vim.keymap.set("n", "?", open_help, opts)
  vim.keymap.set("n", "g?", open_help, opts)
  for index = 1, 9 do
    local key_index = index
    vim.keymap.set("n", tostring(index), function()
      if is_dashboard() and DASHBOARD_TAB_BY_INDEX[key_index] then
        local panel = state.panels.chats or {}
        M.open({
          mode = "dashboard",
          tab = DASHBOARD_TAB_BY_INDEX[key_index],
          show_help = panel.show_help,
        })
        return
      end
      open_number(key_index)
    end, opts)
  end
  vim.keymap.set("n", "dd", delete_selected, opts)
  vim.keymap.set("x", "d", delete_selected, opts)
  vim.keymap.set("n", "q", close, opts)
  vim.keymap.set("n", "<Esc>", close, opts)
end

function M.open(opts)
  opts = opts or {}
  ui.ensure_highlights()
  local bufnr = ensure_buffer()
  local panel = state.panels.chats or {}
  local mode = opts.mode or panel.mode
  local tab = opts.tab or (mode == "dashboard" and panel.tab) or "all"
  local show_help = opts.show_help
  if show_help == nil and mode == "dashboard" then
    show_help = panel.show_help
  end
  if mode == "dashboard" then
    open_backdrop()
  else
    close_backdrop()
  end
  local winid
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    winid = panel.winid
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_set_config(winid, window_config(mode))
  else
    winid = vim.api.nvim_open_win(bufnr, true, window_config(mode))
  end
  configure_window(winid)
  state.panels.chats = {
    bufnr = bufnr,
    winid = winid,
    row_to_session = {},
    row_to_kind = {},
    row_to_action = {},
    number_to_row = {},
    mode = mode,
    tab = tab,
    show_help = show_help,
  }
  attach_maps(bufnr)
  render(bufnr)

  local row_to_session = state.panels.chats.row_to_session or {}
  local row_to_action = state.panels.chats.row_to_action or {}
  local first_row = nil
  for row, _ in pairs(row_to_action) do
    first_row = first_row and math.min(first_row, row) or row
  end
  for row, _ in pairs(row_to_session) do
    first_row = first_row and math.min(first_row, row) or row
  end
  if first_row then
    vim.api.nvim_win_set_cursor(winid, { first_row, 0 })
  end
  return bufnr
end

return M
