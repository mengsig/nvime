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
  local width = math.max(64, math.min(math.floor(columns * 0.74), columns - 6))
  local height = math.max(10, math.min(math.floor(lines * 0.52), lines - 6))
  if cfg.width and type(cfg.width) == "number" then
    width = math.max(64, math.min(cfg.width, columns - 6))
  end
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
    title = " nvime chats ",
    title_pos = "center",
    footer = " 1-9 open | <CR> open | n new | dd delete | visual d delete | r refresh | q close ",
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
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted,CursorLine:NvimeCode"
end

local function close()
  local panel = state.panels.chats
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_close, panel.winid, true)
  end
end

local function format_range(session)
  local selected = session.selection or {}
  local path = selected.path or "(unknown)"
  return string.format("%s:%s-%s", path, tostring(selected.line1 or "?"), tostring(selected.line2 or "?"))
end

local function format_session(index, session)
  local status = session.busy and "running" or "idle"
  local mode = session.mode or "selection"
  local provider = session.provider or "?"
  local native = session.provider_sessions and session.provider_sessions[provider] and "resume" or "local"
  return string.format("%2d  %-7s %-6s %-8s %-6s %s", index, provider, mode, status, native, format_range(session))
end

local function requested_mode()
  local panel = state.panels.chats or {}
  if panel.mode == "ask" or panel.mode == "edit" or panel.mode == "chat" then
    return panel.mode
  end
  return nil
end

local function is_chat_mode()
  return requested_mode() == "chat"
end

local function format_chat_session(index, session)
  local status = session.busy and "running" or "idle"
  local provider = session.provider or "?"
  local native = session.provider_sessions and session.provider_sessions[provider] and "resume" or "local"
  local title = session.title or ("Chat #" .. tostring(session.id or index))
  return string.format("%2d  %-7s %-8s %-6s %s", index, provider, status, native, title)
end

local function render(bufnr)
  local mode = requested_mode()
  local lines = {}
  local row_to_session = {}
  local row_to_action = {}
  local number_to_row = {}

  if mode == "chat" then
    local sessions = chat.sessions()
    lines = {
      "General Conversations",
      "",
    }
    row_to_action[#lines + 1] = {
      type = "new_chat",
    }
    lines[#lines + 1] = " n  start new chat conversation"
    lines[#lines + 1] = ""

    if #sessions == 0 then
      lines[#lines + 1] = "No general chat conversations yet."
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Press n to start one, or <CR> on the new row."
    else
      lines[#lines + 1] = "    agent   status   native title"
      lines[#lines + 1] = "    -----   ------   ------ -----"
      for index, session in ipairs(sessions) do
        local row = #lines + 1
        row_to_session[row] = session.id
        number_to_row[index] = row
        lines[#lines + 1] = format_chat_session(index, session)
      end
    end
  elseif mode then
    local sessions = selection.sessions()
    lines = {
      "Selection Discussions",
      "",
    }
    row_to_action[#lines + 1] = {
      type = "new",
      mode = mode,
    }
    lines[#lines + 1] = " n  start new " .. mode .. " session from current function"
    lines[#lines + 1] = ""
    if #sessions == 0 then
      lines[#lines + 1] = "No highlighted-code discussions yet."
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Select code and press visual <leader>nq or visual <leader>ne, or start from the current function above."
    else
      lines[#lines + 1] = "    agent   lane   status   native file:lines"
      lines[#lines + 1] = "    -----   ----   ------   ------ ----------"
      for index, session in ipairs(sessions) do
        local row = #lines + 1
        row_to_session[row] = session.id
        number_to_row[index] = row
        lines[#lines + 1] = format_session(index, session)
      end
    end
  else
    local sessions = selection.sessions()
    lines = {
      "Selection Discussions",
      "",
    }
    row_to_action[#lines + 1] = {
      type = "new",
      mode = "ask",
    }
    lines[#lines + 1] = " n  start new ask session from current function"
    row_to_action[#lines + 1] = {
      type = "new",
      mode = "edit",
    }
    lines[#lines + 1] = " e  start new edit session from current function"
    lines[#lines + 1] = ""
    if #sessions == 0 then
      lines[#lines + 1] = "No highlighted-code discussions yet."
      lines[#lines + 1] = ""
      lines[#lines + 1] = "Select code and press visual <leader>nq or visual <leader>ne, or start from the current function above."
    else
      lines[#lines + 1] = "    agent   lane   status   native file:lines"
      lines[#lines + 1] = "    -----   ----   ------   ------ ----------"
      for index, session in ipairs(sessions) do
        local row = #lines + 1
        row_to_session[row] = session.id
        number_to_row[index] = row
        lines[#lines + 1] = format_session(index, session)
      end
    end
  end

  set_locked(bufnr, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  set_locked(bufnr, true)

  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
    end_col = #lines[1],
    hl_group = "NvimeHeader",
  })
  for row, session_id in pairs(row_to_session) do
    local session = is_chat_mode() and chat.get_session(session_id) or selection.get_session(session_id)
    if session and session.busy then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
        line_hl_group = "NvimeDiffHunk",
      })
    end
  end

  state.panels.chats.row_to_session = row_to_session
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
    return {
      type = is_chat_mode() and "chat_session" or "session",
      session_id = session_id,
    }
  end
  return nil
end

local function selected_session_ids()
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

  local ids = {}
  local seen = {}
  for row = first, last do
    local session_id = panel.row_to_session and panel.row_to_session[row]
    if session_id and not seen[session_id] then
      seen[session_id] = true
      ids[#ids + 1] = session_id
    end
  end
  return ids
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
  local ids = selected_session_ids()
  if #ids == 0 then
    vim.notify("No nvime " .. (is_chat_mode() and "chat" or "discussion") .. " selected", vim.log.levels.INFO)
    return
  end
  local deleted = is_chat_mode() and chat.delete_sessions(ids) or selection.delete_sessions(ids)
  if deleted > 0 then
    vim.notify("Deleted " .. tostring(deleted) .. " nvime " .. (is_chat_mode() and "chat(s)" or "discussion(s)"), vim.log.levels.INFO)
  end
  M.open({ mode = requested_mode() })
end

local function attach_maps(bufnr)
  local opts = { buffer = bufnr, silent = true }
  vim.keymap.set("n", "<CR>", open_selected, opts)
  vim.keymap.set("n", "o", open_selected, opts)
  vim.keymap.set("n", "i", open_selected, opts)
  vim.keymap.set("n", "n", function()
    open_new(requested_mode() or "ask")
  end, opts)
  vim.keymap.set("n", "e", function()
    if is_chat_mode() then
      open_selected()
      return
    end
    open_new("edit")
  end, opts)
  vim.keymap.set("n", "r", function()
    M.open({ mode = requested_mode() })
  end, opts)
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
