local chat = require("nvime.chat")
local selection = require("nvime.selection")
local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local ns = vim.api.nvim_create_namespace("nvime.chats")

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

local function dimensions()
  local cfg = (state.config or {}).ui or {}
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = math.floor(columns * (cfg.float_width or 0.78))
  local height = math.floor(lines * 0.56)
  if cfg.width and type(cfg.width) == "number" and not (type(cfg.float_width) == "number" and cfg.float_width > 0) then
    width = math.max(64, math.min(cfg.width, columns - 6))
  end
  if type(cfg.float_width) == "number" and cfg.float_width > 0 and cfg.float_width <= 1 then
    width = math.floor(columns * cfg.float_width)
  end
  if type(cfg.float_height) == "number" and cfg.float_height > 0 and cfg.float_height <= 1 then
    height = math.floor(lines * math.min(cfg.float_height, 0.7))
  end
  width = math.max(64, math.min(width, columns - 6))
  height = math.max(12, math.min(height, lines - 6))
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2 - 1)),
    col = math.max(0, math.floor((columns - width) / 2)),
    border = cfg.border or "rounded",
  }
end

local function window_config()
  local dim = dimensions()
  return {
    relative = "editor",
    width = dim.width,
    height = dim.height,
    row = dim.row,
    col = dim.col,
    style = "minimal",
    border = dim.border,
    title = " nvime command center ",
    title_pos = "center",
    footer = " 1-9 open | <CR> open | n new | dd delete | r refresh | ? help | q close ",
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
end

local function open_help()
  local panel = state.panels.chats
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
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
  vim.api.nvim_buf_add_highlight(bufnr, ns, "NvimeHeader", 0, 0, -1)
  for row = 2, 9 do
    vim.api.nvim_buf_add_highlight(bufnr, ns, "NvimeKey", row, 2, 15)
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

local function status_text(session)
  if session.busy then
    return require("nvime.render").spinner_text() .. " running"
  end
  return ui.icon("idle") .. " idle"
end

local function native_text(session, provider_name)
  if session.provider_sessions and session.provider_sessions[provider_name] then
    return ui.icon("resume") .. " resume"
  end
  return ui.icon("local_session") .. " local"
end

local function format_session(index, session)
  local mode = session.mode or "selection"
  local provider = session.provider or "?"
  return string.format(
    "%2d  %-9s %-7s %-6s %-9s %-5s %s",
    index,
    status_text(session),
    provider,
    mode,
    native_text(session, provider),
    ui.relative_time(session.updated_at),
    format_range(session)
  )
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

local function format_chat_session(index, session)
  local provider = session.provider or "?"
  local title = session.title or ("Chat #" .. tostring(session.id or index))
  return string.format(
    "%2d  %-9s %-7s %-9s %-5s %s",
    index,
    status_text(session),
    provider,
    native_text(session, provider),
    ui.relative_time(session.updated_at),
    ui.truncate(title, 52)
  )
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

  if mode == "dashboard" then
    local chat_sessions = chat.sessions()
    local selection_sessions = selection.sessions()
    lines = {
      "Nvime",
      "  No-vibe agent control for review, selection Ask, and reviewed edits",
      "",
      string.format(
        "  %s %d chats   %s %d selections   %s %d running   %s %s",
        ui.icon("chat"),
        #chat_sessions,
        ui.icon("selection"),
        #selection_sessions,
        ui.icon("active"),
        count_all_running(chat_sessions, selection_sessions),
        ui.icon("review"),
        (state.config and state.config.provider) or "claude"
      ),
      "",
      "Actions",
      "-------",
    }
    section_rows[#section_rows + 1] = 1
    meta_rows[#meta_rows + 1] = 2
    meta_rows[#meta_rows + 1] = 4
    row_to_action[#lines + 1] = { type = "new_chat" }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " n  start new review/docs chat"
    row_to_action[#lines + 1] = { type = "new", mode = "ask" }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " a  ask about current function"
    row_to_action[#lines + 1] = { type = "new", mode = "edit" }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " e  edit current function"
    lines[#lines + 1] = ""

    if #chat_sessions > 0 then
      lines[#lines + 1] = "General Conversations"
      section_rows[#section_rows + 1] = #lines
      lines[#lines + 1] = "    status    agent   native    age   title"
      meta_rows[#meta_rows + 1] = #lines
      for index, session in ipairs(chat_sessions) do
        if index > 5 then
          break
        end
        local row = #lines + 1
        row_to_session[row] = session.id
        row_to_kind[row] = "chat"
        number_to_row[#number_to_row + 1] = row
        lines[#lines + 1] = format_chat_session(#number_to_row, session)
      end
      lines[#lines + 1] = ""
    end

    if #selection_sessions > 0 then
      lines[#lines + 1] = "Selection Discussions"
      section_rows[#section_rows + 1] = #lines
      lines[#lines + 1] = "    status    agent   lane   native    age   file:lines"
      meta_rows[#meta_rows + 1] = #lines
      for index, session in ipairs(selection_sessions) do
        if index > 7 or #number_to_row >= 9 then
          break
        end
        local row = #lines + 1
        row_to_session[row] = session.id
        row_to_kind[row] = "selection"
        number_to_row[#number_to_row + 1] = row
        lines[#lines + 1] = format_session(#number_to_row, session)
      end
    end

    if #chat_sessions == 0 and #selection_sessions == 0 then
      lines[#lines + 1] = "No saved nvime sessions yet."
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Press n for review/docs chat, or open a file and use a/e for scoped work."
    end
  elseif mode == "chat" then
    local sessions = chat.sessions()
    lines = {
      "General Conversations",
      "  Mason-style command center for review/docs agents",
      "",
      string.format(
        "  %s %d saved   %s %d running   %s provider %s",
        ui.icon("chat"),
        #sessions,
        ui.icon("active"),
        count_running(sessions),
        ui.icon("review"),
        (state.config and state.config.provider) or "claude"
      ),
      "",
      "Actions",
      "-------",
    }
    section_rows[#section_rows + 1] = 1
    meta_rows[#meta_rows + 1] = 2
    meta_rows[#meta_rows + 1] = 4
    row_to_action[#lines + 1] = {
      type = "new_chat",
    }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " n  start new chat conversation"
    lines[#lines + 1] = ""

    if #sessions == 0 then
      lines[#lines + 1] = "No general chat conversations yet."
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Press n to start one, or <CR> on the new row."
    else
      lines[#lines + 1] = "Sessions"
      section_rows[#section_rows + 1] = #lines
      lines[#lines + 1] = "    status    agent   native    age   title"
      meta_rows[#meta_rows + 1] = #lines
      for index, session in ipairs(sessions) do
        local row = #lines + 1
        row_to_session[row] = session.id
        row_to_kind[row] = "chat"
        number_to_row[index] = row
        lines[#lines + 1] = format_chat_session(index, session)
      end
    end
  elseif mode then
    local sessions = selection.sessions()
    lines = {
      "Selection Discussions",
      "  Focused Ask/Edit workspaces scoped to one file range",
      "",
      string.format(
        "  %s %d saved   %s %d running   %s lane %s",
        ui.icon("selection"),
        #sessions,
        ui.icon("active"),
        count_running(sessions),
        ui.icon(mode),
        mode
      ),
      "",
      "Actions",
      "-------",
    }
    section_rows[#section_rows + 1] = 1
    meta_rows[#meta_rows + 1] = 2
    meta_rows[#meta_rows + 1] = 4
    row_to_action[#lines + 1] = {
      type = "new",
      mode = mode,
    }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " n  start new " .. mode .. " session from current function"
    lines[#lines + 1] = ""
    if #sessions == 0 then
      lines[#lines + 1] = "No highlighted-code discussions yet."
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Select code and press visual <leader>nq or visual <leader>ne, or start from the current function above."
    else
      lines[#lines + 1] = "Sessions"
      section_rows[#section_rows + 1] = #lines
      lines[#lines + 1] = "    status    agent   lane   native    age   file:lines"
      meta_rows[#meta_rows + 1] = #lines
      for index, session in ipairs(sessions) do
        local row = #lines + 1
        row_to_session[row] = session.id
        row_to_kind[row] = "selection"
        number_to_row[index] = row
        lines[#lines + 1] = format_session(index, session)
      end
    end
  else
    local sessions = selection.sessions()
    lines = {
      "Selection Discussions",
      "  Ask, Edit, and diff follow-up sessions from selected code",
      "",
      string.format(
        "  %s %d saved   %s %d running   %s choose ask/edit",
        ui.icon("selection"),
        #sessions,
        ui.icon("active"),
        count_running(sessions),
        ui.icon("key")
      ),
      "",
      "Actions",
      "-------",
    }
    section_rows[#section_rows + 1] = 1
    meta_rows[#meta_rows + 1] = 2
    meta_rows[#meta_rows + 1] = 4
    row_to_action[#lines + 1] = {
      type = "new",
      mode = "ask",
    }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " n  start new ask session from current function"
    row_to_action[#lines + 1] = {
      type = "new",
      mode = "edit",
    }
    action_rows[#lines + 1] = true
    lines[#lines + 1] = " e  start new edit session from current function"
    lines[#lines + 1] = ""
    if #sessions == 0 then
      lines[#lines + 1] = "No highlighted-code discussions yet."
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Select code and press visual <leader>nq or visual <leader>ne, or start from the current function above."
    else
      lines[#lines + 1] = "Sessions"
      section_rows[#section_rows + 1] = #lines
      lines[#lines + 1] = "    status    agent   lane   native    age   file:lines"
      meta_rows[#meta_rows + 1] = #lines
      for index, session in ipairs(sessions) do
        local row = #lines + 1
        row_to_session[row] = session.id
        row_to_kind[row] = "selection"
        number_to_row[index] = row
        lines[#lines + 1] = format_session(index, session)
      end
    end
  end

  set_locked(bufnr, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  set_locked(bufnr, true)

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for _, row in ipairs(section_rows) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      end_col = #(lines[row] or ""),
      hl_group = row == 1 and "NvimeHeader" or "NvimeSection",
    })
  end
  for _, row in ipairs(meta_rows) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      end_col = #(lines[row] or ""),
      hl_group = "NvimeMuted",
    })
  end
  for row, _ in pairs(action_rows) do
    local line = lines[row] or ""
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 1, {
      end_col = math.min(4, #line),
      hl_group = "NvimeKey",
    })
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 4, {
      end_col = #line,
      hl_group = "NvimeUserText",
    })
  end
  for row, session_id in pairs(row_to_session) do
    local kind = row_to_kind[row] or (is_chat_mode() and "chat" or "selection")
    local session = kind == "chat" and chat.get_session(session_id) or selection.get_session(session_id)
    local line = lines[row] or ""
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      end_col = math.min(2, #line),
      hl_group = "NvimeRowIndex",
    })
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
      selection.open_session(item.session_id, { focus_input = true })
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
  for index = 1, 9 do
    local key_index = index
    vim.keymap.set("n", tostring(index), function()
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
  local winid
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    winid = panel.winid
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_set_config(winid, window_config())
  else
    winid = vim.api.nvim_open_win(bufnr, true, window_config())
  end
  configure_window(winid)
  state.panels.chats = {
    bufnr = bufnr,
    winid = winid,
    row_to_session = {},
    row_to_kind = {},
    row_to_action = {},
    number_to_row = {},
    mode = opts.mode,
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
