local state = require("nvime.state")

local M = {}

local highlight_pending = false

local ICONS = {
  active = "●",
  idle = "○",
  success = "✓",
  pending = "…",
  error = "✕",
  warning = "!",
  chat = "◈",
  selection = "◇",
  ask = "?",
  edit = "✎",
  review = "◆",
  resume = "↻",
  local_session = "•",
  new = "+",
  key = "›",
}

local ASCII_ICONS = {
  active = "*",
  idle = "o",
  success = "+",
  pending = ".",
  error = "x",
  warning = "!",
  chat = "#",
  selection = "-",
  ask = "?",
  edit = "e",
  review = "r",
  resume = "~",
  local_session = ".",
  new = "+",
  key = ">",
}

local function define_highlights()
  vim.api.nvim_set_hl(0, "NvimeNormal", { bg = "#0b0d12", fg = "#d7dde8", default = true })
  vim.api.nvim_set_hl(0, "NvimeBackdrop", { bg = "#000000", default = true })
  vim.api.nvim_set_hl(0, "NvimeBorder", { fg = "#8b919e", default = true })
  vim.api.nvim_set_hl(0, "NvimeTitle", { fg = "#dca561", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeSubtitle", { fg = "#a8b4c7", default = true })
  vim.api.nvim_set_hl(0, "NvimeInputNormal", { bg = "#101319", fg = "#d7dde8", default = true })
  vim.api.nvim_set_hl(0, "NvimeInputBorder", { fg = "#8b919e", default = true })
  vim.api.nvim_set_hl(0, "NvimeInputStatus", { fg = "#56b6c2", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeInputPrompt", { fg = "#f4bf75", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeInputGhost", { fg = "#566075", italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeHeader", { fg = "#d7dde8", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeHeaderBlock", { fg = "#222222", bg = "#dca561", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeHeaderBlockSecondary", { fg = "#10141d", bg = "#56b6c2", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeSection", { fg = "#56b6c2", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeHighlightBlock", { fg = "#10141d", bg = "#56b6c2", default = true })
  vim.api.nvim_set_hl(0, "NvimeHighlightBlockBold", { fg = "#10141d", bg = "#56b6c2", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMutedBlock", { fg = "#10141d", bg = "#888888", default = true })
  vim.api.nvim_set_hl(0, "NvimeMutedBlockBold", { fg = "#10141d", bg = "#888888", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeTabActive", { fg = "#10141d", bg = "#56b6c2", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeTabInactive", { fg = "#d7dde8", bg = "#3b414c", default = true })
  vim.api.nvim_set_hl(0, "NvimeTabFaint", { fg = "#10141d", bg = "#555c66", default = true })
  vim.api.nvim_set_hl(0, "NvimeStatus", { fg = "#8bdc7c", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusIdle", { fg = "#6f7a92", default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusRunning", { fg = "#56b6c2", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusSuccess", { fg = "#8bdc7c", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusWarn", { fg = "#f4bf75", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusError", { fg = "#ff6b7a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeHelp", { fg = "#56b6c2", default = true })
  vim.api.nvim_set_hl(0, "NvimeKey", { fg = "#10141d", bg = "#f4bf75", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeRule", { fg = "#2f3540", default = true })
  vim.api.nvim_set_hl(0, "NvimeMuted", { fg = "#6f7a92", default = true })
  vim.api.nvim_set_hl(0, "NvimeFaint", { fg = "#424b5e", default = true })
  vim.api.nvim_set_hl(0, "NvimePrompt", { fg = "#f4bf75", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeUserText", { fg = "#d7dde8", default = true })
  vim.api.nvim_set_hl(0, "NvimeAgent", { fg = "#c8d26a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeExit", { fg = "#6f7a92", italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownHeading", { fg = "#56b6c2", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownStrong", { fg = "#d7dde8", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBullet", { fg = "#8bdc7c", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeQuote", { fg = "#c099ff", italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeCodeFence", { fg = "#56b6c2", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeCode", { fg = "#ccd6e3", bg = "#11151d", default = true })
  vim.api.nvim_set_hl(0, "NvimeDiffAdd", { fg = "#9bd18b", bg = "#16231b", default = true })
  vim.api.nvim_set_hl(0, "NvimeDiffDelete", { fg = "#ff7b86", bg = "#28191f", default = true })
  vim.api.nvim_set_hl(0, "NvimeDiffHunk", { fg = "#d7dde8", bg = "#252b35", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeError", { fg = "#ff6b7a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeCursorLine", { bg = "#171b23", default = true })
  vim.api.nvim_set_hl(0, "NvimeRowIndex", { fg = "#f4bf75", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeRowTitle", { fg = "#d7dde8", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeRowMeta", { fg = "#6f7a92", default = true })
  vim.api.nvim_set_hl(0, "NvimeRowDetail", { fg = "#a8b4c7", default = true })
  vim.api.nvim_set_hl(0, "NvimeProviderClaude", { fg = "#f4bf75", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeProviderCodex", { fg = "#4fd6be", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBadge", { fg = "#10141d", bg = "#4fd6be", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBadgeMuted", { fg = "#d7dde8", bg = "#263142", default = true })
  vim.api.nvim_set_hl(0, "NvimeBadgeSuccess", { fg = "#10141d", bg = "#8bdc7c", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBadgeWarn", { fg = "#10141d", bg = "#f4bf75", bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBadgeError", { fg = "#10141d", bg = "#ff6b7a", bold = true, default = true })
end

function M.ensure_highlights()
  if vim.in_fast_event and vim.in_fast_event() then
    if highlight_pending then
      return
    end
    highlight_pending = true
    vim.schedule(function()
      highlight_pending = false
      define_highlights()
    end)
    return
  end
  define_highlights()
end

function M.icon(name)
  local cfg = (state.config or {}).ui or {}
  local custom = cfg.icons or {}
  if custom[name] then
    return custom[name]
  end
  if cfg.ascii_icons == true then
    return ASCII_ICONS[name] or ""
  end
  return ICONS[name] or ASCII_ICONS[name] or ""
end

function M.truncate(text, max_width)
  text = tostring(text or "")
  max_width = tonumber(max_width) or 0
  if max_width <= 0 or vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  local suffix = "…"
  local suffix_width = vim.fn.strdisplaywidth(suffix)
  if max_width <= suffix_width then
    local first = vim.fn.strcharpart(text, 0, 1)
    return vim.fn.strdisplaywidth(first) <= max_width and first or ""
  end
  local target_width = max_width - suffix_width
  local width = 0
  local out = {}
  for index = 0, vim.fn.strchars(text) - 1 do
    local char = vim.fn.strcharpart(text, index, 1)
    local char_width = vim.fn.strdisplaywidth(char)
    if width + char_width > target_width then
      break
    end
    out[#out + 1] = char
    width = width + char_width
  end
  return table.concat(out) .. suffix
end

function M.relative_time(timestamp)
  timestamp = tonumber(timestamp)
  if not timestamp or timestamp <= 0 then
    return "new"
  end
  local seconds = math.max(0, os.time() - timestamp)
  if seconds < 60 then
    return tostring(seconds) .. "s"
  end
  local minutes = math.floor(seconds / 60)
  if minutes < 60 then
    return tostring(minutes) .. "m"
  end
  local hours = math.floor(minutes / 60)
  if hours < 48 then
    return tostring(hours) .. "h"
  end
  return tostring(math.floor(hours / 24)) .. "d"
end

local function set_scratch_options(bufnr, filetype)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].filetype = filetype or "nvime"
end

local function find_buffer_by_name(name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      return bufnr
    end
  end
  return nil
end

local function ensure_named_buffer(name, filetype)
  local bufnr = find_buffer_by_name(name)
  if bufnr then
    set_scratch_options(bufnr, filetype)
    return bufnr
  end

  bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  set_scratch_options(bufnr, filetype)
  return bufnr
end

local function configure_window(winid)
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

local function float_config(title)
  M.ensure_highlights()
  local ui = state.config.ui or {}
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = ui.width or math.floor(columns * (ui.float_width or 0.82))
  local height = ui.height or math.floor(lines * (ui.float_height or 0.72))

  if type(ui.float_width) == "number" and ui.float_width > 0 and ui.float_width <= 1 then
    width = math.floor(columns * ui.float_width)
  end
  if type(ui.float_height) == "number" and ui.float_height > 0 and ui.float_height <= 1 then
    height = math.floor(lines * ui.float_height)
  end

  width = math.max(48, math.min(width, columns - 4))
  height = math.max(12, math.min(height, lines - 4))

  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((lines - height) / 2 - 1),
    col = math.floor((columns - width) / 2),
    style = "minimal",
    border = ui.border or "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
    footer = " enter/i/o input | p/tab provider | P choose | q close ",
    footer_pos = "center",
  }
end

local function open_float(bufnr, name, title)
  local existing = state.panels[name]
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_win_set_buf(existing.winid, bufnr)
    vim.api.nvim_win_set_config(existing.winid, float_config(title))
    configure_window(existing.winid)
    return existing.winid
  end

  local winid = vim.api.nvim_open_win(bufnr, true, float_config(title))
  configure_window(winid)
  return winid
end

local function open_split(bufnr, name)
  local existing = state.panels[name]
  if existing and vim.api.nvim_buf_is_valid(existing.bufnr) then
    if existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
      return existing.winid
    end
    local side = state.config.ui.side == "left" and "topleft" or "botright"
    vim.cmd(side .. " vertical " .. tostring(state.config.ui.width) .. "split")
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, existing.bufnr)
    existing.winid = winid
    return winid
  end

  local side = state.config.ui.side == "left" and "topleft" or "botright"
  vim.cmd(side .. " vertical " .. tostring(state.config.ui.width) .. "new")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  configure_window(winid)

  return winid
end

local function open_buffer(name, title, filetype)
  local bufnr = ensure_named_buffer("nvime://" .. name, filetype)
  local layout = (state.config.ui or {}).layout or "float"
  local winid
  if layout == "split" or layout == "side" then
    winid = open_split(bufnr, name)
  else
    winid = open_float(bufnr, name, title)
  end

  state.panels[name] = {
    bufnr = bufnr,
    winid = winid,
  }

  return bufnr, winid
end

function M.panel(name, title, filetype)
  local bufnr = open_buffer(name, title, filetype)
  local modifiable = vim.bo[bufnr].modifiable
  local readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  if vim.api.nvim_buf_line_count(bufnr) == 1 and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" then
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# " .. title, "" })
  end
  vim.bo[bufnr].modifiable = modifiable
  vim.bo[bufnr].readonly = readonly
  return bufnr
end

function M.update_title(name, title)
  local panel = state.panels[name]
  if not panel or not panel.winid or not vim.api.nvim_win_is_valid(panel.winid) then
    return
  end
  local cfg = vim.api.nvim_win_get_config(panel.winid)
  if cfg.relative ~= "" then
    vim.api.nvim_win_set_config(panel.winid, float_config(title))
  end
end

function M.clear(bufnr, lines)
  local modifiable = vim.bo[bufnr].modifiable
  local readonly = vim.bo[bufnr].readonly
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  vim.bo[bufnr].modifiable = modifiable
  vim.bo[bufnr].readonly = readonly
end

function M.append(bufnr, text)
  if not bufnr then
    return
  end
  if not text or text == "" then
    return
  end

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    local is_prompt = vim.bo[bufnr].buftype == "prompt"
    local modifiable = vim.bo[bufnr].modifiable
    local readonly = vim.bo[bufnr].readonly
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    local target = line_count - 1
    if is_prompt then
      target = math.max(0, line_count - 2)
    end
    local current = vim.api.nvim_buf_get_lines(bufnr, target, target + 1, false)[1] or ""
    local parts = vim.split(text, "\n", { plain = true })
    if target >= line_count - 1 and is_prompt then
      vim.api.nvim_buf_set_lines(bufnr, line_count - 1, line_count - 1, false, { parts[1] })
    else
      vim.api.nvim_buf_set_lines(bufnr, target, target + 1, false, { current .. parts[1] })
    end
    if #parts > 1 then
      local rest = {}
      for i = 2, #parts do
        rest[#rest + 1] = parts[i]
      end
      local insert_at = target + 1
      if is_prompt then
        insert_at = math.max(target + 1, vim.api.nvim_buf_line_count(bufnr) - 1)
      end
      vim.api.nvim_buf_set_lines(bufnr, insert_at, insert_at, false, rest)
    end
    local panel = state.panels.chat
    if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) and panel.bufnr == bufnr then
      vim.api.nvim_win_set_cursor(panel.winid, { vim.api.nvim_buf_line_count(bufnr), 0 })
    end
    vim.bo[bufnr].modifiable = modifiable
    vim.bo[bufnr].readonly = readonly
  end)
end

return M
