local progress = require("nvime.progress")
local render = require("nvime.render")
local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local SPINNER_NS = vim.api.nvim_create_namespace("nvime.spinner.float")
local PANEL_KEY = "spinner"
local TICK_MS = 120
local PADDING = 2

local timer = nil

local function stop_timer()
  if timer then
    pcall(function()
      timer:stop()
      timer:close()
    end)
    timer = nil
  end
end

local function busy_sessions()
  local out = {}
  for _, session in ipairs((state.chat or {}).sessions or {}) do
    if session.busy then
      out[#out + 1] = { session = session, kind = "chat" }
    end
  end
  for _, session in ipairs((state.selection or {}).sessions or {}) do
    if session.busy then
      out[#out + 1] = { session = session, kind = "selection" }
    end
  end
  return out
end

local function close_float()
  local panel = state.panels[PANEL_KEY]
  if not panel then
    return
  end
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_close, panel.winid, true)
  end
  if panel.bufnr and vim.api.nvim_buf_is_valid(panel.bufnr) then
    pcall(vim.api.nvim_buf_delete, panel.bufnr, { force = true })
  end
  state.panels[PANEL_KEY] = nil
end

local function position(width, height)
  local row = math.max(0, vim.o.lines - 2 - height)
  local col = math.max(0, vim.o.columns - width - 2)
  return row, col
end

local function ensure_float(width, height)
  ui.ensure_highlights()
  local panel = state.panels[PANEL_KEY]
  local row, col = position(width, height)
  if
    panel
    and panel.winid
    and vim.api.nvim_win_is_valid(panel.winid)
    and panel.bufnr
    and vim.api.nvim_buf_is_valid(panel.bufnr)
  then
    pcall(vim.api.nvim_win_set_config, panel.winid, {
      relative = "editor",
      width = width,
      height = height,
      row = row,
      col = col,
    })
    return panel
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false

  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    focusable = false,
    zindex = 65,
  })
  vim.wo[winid].winblend = 0
  vim.wo[winid].winhighlight = "NormalFloat:NvimeNormal"
  state.panels[PANEL_KEY] = { bufnr = bufnr, winid = winid }
  return state.panels[PANEL_KEY]
end

local function format_row(item, frame)
  local session = item.session
  local provider_name = session.provider or "?"
  local lane = item.kind == "chat" and "review/docs" or (session.mode or "selection")
  local detail = progress.compact(session.progress or "")
  detail = detail:gsub("^" .. provider_name .. "%s*", "")
  if detail == "" then
    detail = "working"
  end
  return string.format(" %s %s · %s · %s ", frame, provider_name, lane, detail), provider_name
end

local function ensure_timer()
  if timer then
    return
  end
  local uv = vim.uv or vim.loop
  if not uv or not uv.new_timer then
    return
  end
  timer = uv.new_timer()
  timer:start(TICK_MS, TICK_MS, function()
    vim.schedule(function()
      if #busy_sessions() == 0 then
        stop_timer()
        close_float()
        return
      end
      M.update()
    end)
  end)
end

function M.update()
  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(M.update)
    return
  end
  local items = busy_sessions()
  if #items == 0 then
    stop_timer()
    close_float()
    return
  end
  ensure_timer()

  local frame = render.spinner_text()
  local rows = {}
  local providers = {}
  local frame_bytes = #frame
  local max_width = 0
  for _, item in ipairs(items) do
    local text, provider_name = format_row(item, frame)
    rows[#rows + 1] = text
    providers[#providers + 1] = provider_name
    max_width = math.max(max_width, vim.fn.strdisplaywidth(text))
  end

  local width = math.min(max_width + PADDING, math.max(20, vim.o.columns - 4))
  local height = #rows
  local panel = ensure_float(width, height)
  if not panel then
    return
  end

  pcall(vim.api.nvim_buf_set_lines, panel.bufnr, 0, -1, false, rows)
  pcall(vim.api.nvim_buf_clear_namespace, panel.bufnr, SPINNER_NS, 0, -1)

  for i, text in ipairs(rows) do
    local row = i - 1
    local provider_name = providers[i]
    local provider_hl = provider_name == "claude" and "NvimeProviderClaude" or "NvimeProviderCodex"
    local frame_start = 1
    local frame_end = frame_start + frame_bytes
    pcall(vim.api.nvim_buf_set_extmark, panel.bufnr, SPINNER_NS, row, frame_start, {
      end_col = frame_end,
      hl_group = "NvimeStatusRunning",
    })
    local provider_start = frame_end + 1
    local provider_end = provider_start + #provider_name
    pcall(vim.api.nvim_buf_set_extmark, panel.bufnr, SPINNER_NS, row, provider_start, {
      end_col = provider_end,
      hl_group = provider_hl,
    })
    pcall(vim.api.nvim_buf_set_extmark, panel.bufnr, SPINNER_NS, row, provider_end, {
      end_col = #text,
      hl_group = "NvimeMuted",
    })
  end
end

function M.close()
  stop_timer()
  close_float()
end

return M
