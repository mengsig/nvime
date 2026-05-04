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
    footer = " <CR> open | n new | r refresh | q close ",
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
  if panel.mode == "ask" or panel.mode == "edit" then
    return panel.mode
  end
  return nil
end

local function render(bufnr)
  local sessions = selection.sessions()
  local mode = requested_mode()
  local lines = {
    "Selection Discussions",
    "",
  }
  local row_to_session = {}
  local row_to_action = {}

  if mode then
    row_to_action[#lines + 1] = {
      type = "new",
      mode = mode,
    }
    lines[#lines + 1] = " n  start new " .. mode .. " session from current function"
    lines[#lines + 1] = ""
  else
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
  end

  if #sessions == 0 then
    lines[#lines + 1] = "No highlighted-code discussions yet."
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Select code and press visual <leader>nq or visual <leader>ne, or start from the current function above."
  else
    lines[#lines + 1] = "    agent   lane   status   native file:lines"
    lines[#lines + 1] = "    -----   ----   ------   ------ ----------"
    for index, session in ipairs(sessions) do
      row_to_session[#lines + 1] = session.id
      lines[#lines + 1] = format_session(index, session)
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
    local session = selection.get_session(session_id)
    if session and session.busy then
      vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
        line_hl_group = "NvimeDiffHunk",
      })
    end
  end

  state.panels.chats.row_to_session = row_to_session
  state.panels.chats.row_to_action = row_to_action
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
      type = "session",
      session_id = session_id,
    }
  end
  return nil
end

local function open_selected()
  local item = selected_item()
  if not item then
    return
  end
  close()
  if item.type == "new" then
    require("nvime." .. item.mode).start({
      new_session = true,
    })
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

local function open_new(mode)
  close()
  require("nvime." .. mode).start({
    new_session = true,
  })
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
    open_new("edit")
  end, opts)
  vim.keymap.set("n", "r", function()
    M.open({ mode = requested_mode() })
  end, opts)
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
