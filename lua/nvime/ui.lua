local state = require("nvime.state")

local M = {}

local highlight_pending = false

-- Three icon tiers, selected by config (see M.icon):
--   1. NERD_ICONS  — Nerd Font glyphs (default). The state-of-the-art look;
--      every glyph is a stable FontAwesome-4 codepoint (U+F0xx–U+F1xx) that
--      Nerd Fonts have carried unchanged across v2/v3, so no tofu on a real
--      Nerd Font.
--   2. UNICODE_ICONS — geometric Unicode (ui.nerd_font = false). Works in any
--      terminal with decent Unicode coverage, no Nerd Font required.
--   3. ASCII_ICONS — pure ASCII (ui.ascii_icons = true). The last-resort
--      fallback for minimal terminals.
-- Nerd Font glyphs are written as \u{...} escapes, not literal bytes: the
-- codepoints live in the Private Use Area and several tools mangle raw PUA
-- bytes. The escapes are plain ASCII in source and decode to the real glyph at
-- runtime (LuaJIT). Every codepoint is a stable FontAwesome-4 mapping.
local NERD_ICONS = {
  active = "\u{f111}", -- filled circle (busy)
  idle = "\u{f10c}", -- hollow circle
  success = "\u{f00c}", -- check
  pending = "\u{f192}", -- dot-circle (in progress)
  error = "\u{f00d}", -- times
  warning = "\u{f071}", -- warning triangle
  chat = "\u{f075}", -- comment
  selection = "\u{f121}", -- code range
  ask = "\u{f059}", -- question circle
  edit = "\u{f040}", -- pencil
  review = "\u{f06e}", -- eye
  resume = "\u{f021}", -- refresh
  local_session = "\u{f015}", -- home (local, not resumed)
  new = "\u{f067}", -- plus
  key = "\u{f054}", -- chevron (key hint pointer)
  brand = "\u{f0e7}", -- bolt — the nvime mark
  folder = "\u{f07b}", -- folder (files)
  list = "\u{f03a}", -- list (steps)
}

local UNICODE_ICONS = {
  active = "●",
  idle = "○",
  success = "✓",
  pending = "◐",
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
  brand = "◆",
  folder = "▸",
  list = "≡",
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
  brand = "*",
  folder = ">",
  list = "=",
}

-- nvime palette. A single cohesive dark scheme (Tokyo-Night-Moon lineage):
-- a cool blue-tinted base with depth, harmonised accents tuned for legibility
-- against the panel background, and a clear semantic role for every hue. All
-- decoration groups below map through this table so the look stays consistent
-- across the dashboard, plan, diff, and chat surfaces — and so retuning is a
-- one-line change instead of a hex-hunt across the file.
local C = {
  -- Surfaces (deepest → most elevated)
  backdrop = "#15161e", -- dim layer behind floats
  bg = "#1a1b26", -- normal panel background
  bg_input = "#1e2030", -- input / code surfaces (slightly raised)
  bg_band = "#222436", -- heading band, badge-muted, raised chips
  bg_cursor = "#2f334d", -- cursor line / selected row

  -- Structure
  border = "#545c7e", -- float border (soft but legible)
  rule = "#2d3149", -- dividers / horizontal rules
  faint = "#3b4261", -- markers, punctuation, faint glyphs

  -- Text
  fg = "#c8d3f5", -- primary body text
  fg_bright = "#e4e9f7", -- emphasis / bright body (strong, intent)
  fg_dim = "#a9b1d6", -- secondary text
  muted = "#828bb8", -- meta / muted labels
  comment = "#636da6", -- ghost text / urls / deep mute

  -- Accents
  blue = "#82aaff",
  cyan = "#86e1fc",
  teal = "#4fd6be",
  green = "#c3e88d",
  yellow = "#ffc777",
  orange = "#ff966c",
  red = "#ff757f",
  magenta = "#c099ff",

  -- Accent washes (saturated fg over a tinted bg)
  add_bg = "#22332b",
  del_bg = "#3a2230",
  hunk_bg = "#2d3149",
  warn_bg = "#332b18",
}

local function define_highlights()
  vim.api.nvim_set_hl(0, "NvimeNormal", { bg = C.bg, fg = C.fg, default = true })
  vim.api.nvim_set_hl(0, "NvimeBackdrop", { bg = C.backdrop, default = true })
  vim.api.nvim_set_hl(0, "NvimeBorder", { fg = C.border, default = true })
  vim.api.nvim_set_hl(0, "NvimeTitle", { fg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeSubtitle", { fg = C.fg_dim, default = true })
  vim.api.nvim_set_hl(0, "NvimeInputNormal", { bg = C.bg_input, fg = C.fg, default = true })
  vim.api.nvim_set_hl(0, "NvimeInputBorder", { fg = C.border, default = true })
  vim.api.nvim_set_hl(0, "NvimeInputStatus", { fg = C.cyan, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeInputPrompt", { fg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeInputGhost", { fg = C.comment, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeHeader", { fg = C.fg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeHeaderBlock", { fg = C.bg, bg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeHeaderBlockSecondary", { fg = C.bg, bg = C.cyan, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeSection", { fg = C.cyan, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeSectionBand", { bg = C.bg_band, default = true })
  vim.api.nvim_set_hl(0, "NvimeHighlightBlock", { fg = C.bg, bg = C.cyan, default = true })
  vim.api.nvim_set_hl(0, "NvimeHighlightBlockBold", { fg = C.bg, bg = C.cyan, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMutedBlock", { fg = C.bg, bg = C.muted, default = true })
  vim.api.nvim_set_hl(0, "NvimeMutedBlockBold", { fg = C.bg, bg = C.muted, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeTabActive", { fg = C.cyan, bold = true, underline = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeTabInactive", { fg = C.muted, default = true })
  vim.api.nvim_set_hl(0, "NvimeTabFaint", { fg = C.faint, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatus", { fg = C.green, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusIdle", { fg = C.muted, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusRunning", { fg = C.blue, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusSuccess", { fg = C.green, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusWarn", { fg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeStatusError", { fg = C.red, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeHelp", { fg = C.cyan, default = true })
  vim.api.nvim_set_hl(0, "NvimeKey", { fg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeRule", { fg = C.rule, default = true })
  vim.api.nvim_set_hl(0, "NvimeMuted", { fg = C.muted, default = true })
  vim.api.nvim_set_hl(0, "NvimeFaint", { fg = C.faint, default = true })
  vim.api.nvim_set_hl(0, "NvimePrompt", { fg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeUserText", { fg = C.fg, default = true })
  vim.api.nvim_set_hl(0, "NvimeAgent", { fg = C.teal, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeExit", { fg = C.muted, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownHeading", { fg = C.cyan, bold = true, default = true })
  -- Heading hierarchy: H1 brightest + bold, H2/H3 saturated, H4+ italic.
  -- Markers (`#`, `##`, …) stay visible — we color them muted so structure is
  -- legible without hiding any text. H1/H2/H3 share a single subtle band so
  -- the heading row gets its own register without injecting per-level hue
  -- backgrounds (which read as busy next to the rule line and inline chips).
  vim.api.nvim_set_hl(0, "NvimeMarkdownH1", { fg = C.yellow, bg = C.bg_band, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownH2", { fg = C.cyan, bg = C.bg_band, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownH3", { fg = C.teal, bg = C.bg_band, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownH4", { fg = C.fg_dim, bold = true, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownH5", { fg = C.muted, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownH6", { fg = C.comment, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownHeadingMarker", { fg = C.faint, default = true })
  -- Strong / emphasis / inline-code show up MANY times per agent reply.
  -- If each one carries a saturated colour, the panel reads as visual
  -- chaos — every other word is a different highlight. Keep them subtle:
  -- weight + slant + foreground tint only, no backgrounds.
  --
  -- IMPORTANT: these three intentionally do NOT use `default = true`.
  -- Some user colorschemes / theme frameworks predefine arbitrary
  -- nvime.* group names with their own colours (red bg has been
  -- observed) which `default = true` would honour, breaking our calm
  -- palette. Force-set so nvime always wins for its own decoration
  -- groups; users who really want a custom look can `:hi NvimeMarkdown*`
  -- after setup() returns and our ColorScheme autocmd preserves it via
  -- the same definition cycle.
  vim.api.nvim_set_hl(0, "NvimeMarkdownStrong", { fg = C.fg_bright, bold = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownEmphasis", { fg = C.fg_dim, italic = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownStrike", { fg = C.muted, strikethrough = true })
  -- Inline code: foreground-only signal (no chip background) so we can't
  -- conflict with a colorscheme that defines a red bg, with hardware
  -- rendering our dark-navy as muddy red, or with overlays. teal + italic
  -- reads as code and stays distinct from emphasis-italic (dim) and
  -- links (cyan + underline) by both hue and decoration.
  vim.api.nvim_set_hl(0, "NvimeMarkdownInlineCode", { fg = C.teal, italic = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownLinkText", { fg = C.cyan, underline = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownLinkUrl", { fg = C.comment, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeMarkdownPunct", { fg = C.faint, default = true })
  -- Bullets / numbered list markers: muted accent so they delineate
  -- structure without competing with the content. Saturated bright was
  -- overwhelming when every list item lit up.
  vim.api.nvim_set_hl(0, "NvimeBullet", { fg = C.muted, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBulletNumber", { fg = C.muted, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeQuote", { fg = C.magenta, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeQuoteGutter", { fg = C.magenta, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeCodeFence", { fg = C.teal, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeCodeLang", { fg = C.yellow, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeCode", { fg = C.fg_dim, bg = C.bg_input, default = true })
  -- Diff add / delete backgrounds need to be unambiguously green / red:
  -- the user reads them at a glance to tell additions from deletions.
  -- Force-set with no `default = true` so a user colorscheme that links
  -- these custom group names can never paint them gray or
  -- red-where-it-should-be-green.
  vim.api.nvim_set_hl(0, "NvimeDiffAdd", { fg = C.green, bg = C.add_bg })
  vim.api.nvim_set_hl(0, "NvimeDiffDelete", { fg = C.red, bg = C.del_bg })
  vim.api.nvim_set_hl(0, "NvimeDiffHunk", { fg = C.fg, bg = C.hunk_bg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeConflict", { fg = C.yellow, bg = C.warn_bg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeError", { fg = C.red, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeCursorLine", { bg = C.bg_cursor, default = true })
  vim.api.nvim_set_hl(0, "NvimeRowIndex", { fg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeRowTitle", { fg = C.fg, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeRowMeta", { fg = C.muted, default = true })
  vim.api.nvim_set_hl(0, "NvimeRowDetail", { fg = C.fg_dim, default = true })
  vim.api.nvim_set_hl(0, "NvimeProviderClaude", { fg = C.orange, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeProviderCodex", { fg = C.teal, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBadge", { fg = C.bg, bg = C.teal, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBadgeMuted", { fg = C.fg, bg = C.bg_band, default = true })
  vim.api.nvim_set_hl(0, "NvimeBadgeSuccess", { fg = C.bg, bg = C.green, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBadgeWarn", { fg = C.bg, bg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimeBadgeError", { fg = C.bg, bg = C.red, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanHeading", { fg = C.cyan, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanRule", { fg = C.rule, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanBadgeKey", { fg = C.bg, bg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanStepDone", { fg = C.green, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanStepProgress", { fg = C.blue, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanStepBlocked", { fg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanStepPending", { fg = C.fg_dim, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanMeta", { fg = C.muted, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanFooter", { fg = C.muted, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanProgressFill", { fg = C.green, bg = C.add_bg, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanProgressActive", { fg = C.blue, bg = C.bg_input, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanProgressTrack", { fg = C.faint, bg = C.bg_input, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanStepIndex", { fg = C.bg, bg = C.blue, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanStepIndexDone", { fg = C.bg, bg = C.green, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanStepIndexBlocked", { fg = C.bg, bg = C.yellow, bold = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanStepIndexPending", { fg = C.fg, bg = C.bg_band, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanWhy", { fg = C.fg_dim, italic = true, default = true })
  -- Step intent lines wrap to multiple visual rows when long; bolding the
  -- whole sentence becomes a wall of bold and shouts. Use bright body fg
  -- without bold and let inline_spans (`code`, **bold**, _em_) provide the
  -- visual anchors.
  vim.api.nvim_set_hl(0, "NvimePlanIntent", { fg = C.fg_bright, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanFile", { fg = C.cyan, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanRange", { fg = C.muted, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanMetaLabel", { fg = C.fg_dim, bold = true, italic = true, default = true })
  vim.api.nvim_set_hl(0, "NvimePlanHeadingMarker", { fg = C.faint, default = true })
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

-- Re-apply our defaults whenever a colorscheme load wipes them. Without
-- this, `:colorscheme X` after setup() leaves nvime's markdown / plan /
-- diff highlights as the user's theme leaves them — usually unset, which
-- means agent prose loses its bold/italic/code coloring entirely until
-- the next panel render. Idempotent: define_highlights() uses
-- `default = true` so the user's overrides still win.
local colorscheme_group = vim.api.nvim_create_augroup("NvimeColorScheme", { clear = true })
vim.api.nvim_create_autocmd("ColorScheme", {
  group = colorscheme_group,
  callback = function()
    M.ensure_highlights()
  end,
})

function M.icon(name)
  local cfg = (state.config or {}).ui or {}
  local custom = cfg.icons or {}
  if custom[name] then
    return custom[name]
  end
  if cfg.ascii_icons == true then
    return ASCII_ICONS[name] or ""
  end
  if cfg.nerd_font == false then
    return UNICODE_ICONS[name] or ASCII_ICONS[name] or ""
  end
  return NERD_ICONS[name] or UNICODE_ICONS[name] or ASCII_ICONS[name] or ""
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

-- Shared chrome for every nvime panel float. Centralized here (ui.lua owns the
-- highlight/float layer) so the winhighlight map and the signcolumn-as-padding
-- trick live in one place instead of drifting across the per-module
-- configure_window copies. opts.wrap defaults true; opts.cursorline false.
local PANEL_WINHL =
  "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted,SignColumn:NvimeNormal,CursorLine:NvimeCursorLine"

function M.configure_panel_window(winid, opts)
  opts = opts or {}
  vim.wo[winid].wrap = opts.wrap ~= false
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  -- A 1-cell signcolumn we never put signs in is the cheapest way to give the
  -- panel real left padding — content stops hugging the border and the float
  -- reads as a card. SignColumn is mapped to the panel bg so the gutter is
  -- invisible padding, not a stripe.
  vim.wo[winid].signcolumn = "yes:1"
  vim.wo[winid].cursorline = opts.cursorline == true
  vim.wo[winid].spell = false
  vim.wo[winid].winblend = 0
  vim.wo[winid].winhighlight = PANEL_WINHL
end

local function configure_window(winid)
  M.configure_panel_window(winid, { wrap = true, cursorline = false })
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
    title = " " .. M.icon("brand") .. "  " .. title .. " ",
    title_pos = "center",
    footer = " <CR> input · p provider · P choose · q close ",
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

return M
