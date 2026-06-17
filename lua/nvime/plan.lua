local agents = require("nvime.agents")
local audit = require("nvime.audit")
local git = require("nvime.git")
local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local SCHEMA_VERSION = 1
local PLAN_NS = vim.api.nvim_create_namespace("nvime.plan.view")
local PICKER_NS = vim.api.nvim_create_namespace("nvime.plan.picker")
local BACKDROP_NS = vim.api.nvim_create_namespace("nvime.plan.backdrop")
local STATUS_ORDER = { pending = 1, in_progress = 2, blocked = 3, done = 4, abandoned = 5 }
local STATUSES = { "pending", "in_progress", "done", "blocked", "abandoned" }

local function plan_config()
  return (state.config or {}).plan or {}
end

local function plans_dir()
  local cfg = plan_config()
  if cfg.dir and cfg.dir ~= "" then
    return vim.fn.fnamemodify(cfg.dir, ":p"):gsub("/+$", "")
  end
  local root = git.root()
  if root then
    return root .. "/.nvime/plans"
  end
  return vim.fn.stdpath("state") .. "/nvime/plans"
end

local function plan_dir_for(id)
  return plans_dir() .. "/" .. id
end

local function plan_json_path(id)
  return plan_dir_for(id) .. "/plan.json"
end

local function plan_md_path(id)
  return plan_dir_for(id) .. "/plan.md"
end

local function index_path()
  return plans_dir() .. "/index.json"
end

local function now_ts()
  return os.time()
end

local function ensure_dir(path)
  vim.fn.mkdir(path, "p")
end

local function read_json(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or not raw or #raw == 0 then
    return nil
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function write_json(path, data)
  ensure_dir(vim.fn.fnamemodify(path, ":h"))
  local ok, encoded = pcall(vim.json.encode, data)
  if not ok then
    return false, encoded
  end
  local fd, err = io.open(path, "w")
  if not fd then
    return false, err
  end
  local write_ok, write_err = pcall(function()
    fd:write(encoded)
    fd:write("\n")
  end)
  local close_ok, closed, close_err = pcall(function()
    return fd:close()
  end)
  if not write_ok then
    return false, write_err
  end
  if not close_ok then
    return false, closed
  elseif not closed then
    return false, close_err
  end
  return true
end

local function clamp_int(value, fallback)
  value = tonumber(value)
  if not value then
    return fallback
  end
  return math.floor(value)
end

local function step_status(step)
  local status = step and step.status or "pending"
  if not STATUS_ORDER[status] then
    return "pending"
  end
  return status
end

local function status_icon(status)
  if status == "done" then
    return ui.icon("success") ~= "" and ui.icon("success") or "v"
  end
  if status == "in_progress" then
    return ui.icon("active") ~= "" and ui.icon("active") or "*"
  end
  if status == "blocked" then
    return ui.icon("error") ~= "" and ui.icon("error") or "x"
  end
  if status == "abandoned" then
    return "·"
  end
  return ui.icon("idle") ~= "" and ui.icon("idle") or "o"
end

local function status_hl(status)
  if status == "done" then
    return "NvimePlanStepDone"
  end
  if status == "in_progress" then
    return "NvimePlanStepProgress"
  end
  if status == "blocked" then
    return "NvimePlanStepBlocked"
  end
  if status == "abandoned" then
    return "NvimeFaint"
  end
  return "NvimePlanStepPending"
end

local function find_step(plan, step_id)
  step_id = clamp_int(step_id, nil)
  if not step_id then
    return nil
  end
  for _, step in ipairs(plan.steps or {}) do
    if step.id == step_id then
      return step
    end
  end
  return nil
end

local function range_label(step)
  if step.range == "new" or step.range == nil then
    return "new file"
  end
  if type(step.range) == "table" then
    local l1 = step.range.line1 or step.range[1]
    local l2 = step.range.line2 or step.range[2]
    if l1 and l2 then
      if l1 == l2 then
        return "L" .. l1
      end
      return "L" .. l1 .. "-" .. l2
    end
  end
  return tostring(step.range or "?")
end

local function counts_for_plan(plan)
  local out = { pending = 0, in_progress = 0, done = 0, blocked = 0, abandoned = 0, total = 0 }
  for _, step in ipairs(plan.steps or {}) do
    local s = step_status(step)
    out[s] = (out[s] or 0) + 1
    out.total = out.total + 1
  end
  return out
end

local function plan_progress_label(plan)
  local c = counts_for_plan(plan)
  if c.total == 0 then
    return "no steps"
  end
  if c.done + c.abandoned == c.total then
    return "complete (" .. c.done .. "/" .. c.total .. ")"
  end
  local parts = {}
  if c.done > 0 then
    parts[#parts + 1] = c.done .. " done"
  end
  if c.in_progress > 0 then
    parts[#parts + 1] = c.in_progress .. " in progress"
  end
  if c.blocked > 0 then
    parts[#parts + 1] = c.blocked .. " blocked"
  end
  if c.pending > 0 then
    parts[#parts + 1] = c.pending .. " pending"
  end
  if #parts == 0 then
    return c.total .. " steps"
  end
  return table.concat(parts, " · ")
end

local function plan_overall_status(plan)
  local c = counts_for_plan(plan)
  if c.total == 0 then
    return "draft"
  end
  if c.done + c.abandoned == c.total then
    return "done"
  end
  if c.blocked > 0 then
    return "blocked"
  end
  if c.in_progress > 0 then
    return "in_progress"
  end
  return "pending"
end

local function load_index()
  local data = read_json(index_path())
  if type(data) ~= "table" or type(data.plans) ~= "table" then
    return { version = SCHEMA_VERSION, plans = {} }
  end
  return data
end

local function save_index(plans)
  local entries = {}
  for _, plan in ipairs(plans or {}) do
    entries[#entries + 1] = {
      id = plan.id,
      title = plan.title,
      status = plan_overall_status(plan),
      step_count = #(plan.steps or {}),
      done = counts_for_plan(plan).done,
      created_at = plan.created_at,
      updated_at = plan.updated_at,
    }
  end
  table.sort(entries, function(a, b)
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)
  return write_json(index_path(), { version = SCHEMA_VERSION, plans = entries })
end

local function migrate_plan(plan)
  if type(plan) ~= "table" then
    return nil
  end
  local version = tonumber(plan.version) or SCHEMA_VERSION
  if version > SCHEMA_VERSION then
    vim.notify("nvime plan was written by a newer version: " .. tostring(plan.id), vim.log.levels.WARN)
    return nil
  end
  plan.version = SCHEMA_VERSION
  plan.steps = plan.steps or {}
  plan.acceptance = plan.acceptance or {}
  for index, step in ipairs(plan.steps) do
    step.id = step.id or index
    step.status = step_status(step)
    step.depends_on = step.depends_on or {}
    step.tests = step.tests or {}
  end
  return plan
end

local function load_plan(id)
  local plan = read_json(plan_json_path(id))
  if not plan then
    return nil
  end
  return migrate_plan(plan)
end

local function discover_plans()
  local dir = plans_dir()
  local plans = {}
  if vim.fn.isdirectory(dir) ~= 1 then
    return plans
  end
  local uv = vim.uv or vim.loop
  local scanner = uv.fs_scandir(dir)
  if not scanner then
    return plans
  end
  while true do
    local name, kind = uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    if kind == "directory" and name:match("^%d+%-") then
      local plan = load_plan(name)
      if plan then
        plans[#plans + 1] = plan
      end
    end
  end
  table.sort(plans, function(a, b)
    return (a.updated_at or a.created_at or 0) > (b.updated_at or b.created_at or 0)
  end)
  return plans
end

function M.plans()
  if not state.plan.loaded then
    state.plan.plans = discover_plans()
    state.plan.loaded = true
  end
  return state.plan.plans or {}
end

function M.refresh()
  state.plan.plans = discover_plans()
  state.plan.loaded = true
  return state.plan.plans
end

function M.get(id)
  for _, plan in ipairs(M.plans()) do
    if plan.id == id then
      return plan
    end
  end
  return nil
end

local function persist_plan(plan)
  plan.updated_at = now_ts()
  plan.version = SCHEMA_VERSION
  local ok, err = write_json(plan_json_path(plan.id), plan)
  if not ok then
    vim.notify("nvime: could not write plan: " .. tostring(err), vim.log.levels.ERROR)
    return false
  end
  M.refresh()
  save_index(M.plans())
  return true
end

local function next_plan_number()
  local highest = 0
  for _, plan in ipairs(M.plans()) do
    local num = tonumber((plan.id or ""):match("^(%d+)%-"))
    if num and num > highest then
      highest = num
    end
  end
  return highest + 1
end

local function slugify(text)
  text = (text or ""):lower()
  text = text:gsub("[^a-z0-9]+", "-")
  text = text:gsub("^-+", ""):gsub("-+$", "")
  if text == "" then
    text = "plan"
  end
  if #text > 40 then
    text = text:sub(1, 40):gsub("-+$", "")
  end
  return text
end

local function format_id(number, slug)
  return string.format("%04d-%s", number, slug)
end

-- ============================================================================
-- Plan view buffer
-- ============================================================================

local function buffer_name_for(id)
  return "nvime://plan/" .. id
end

local function find_buffer(name)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) == name then
      return bufnr
    end
  end
  return nil
end

local function dimensions()
  local cfg = (state.config or {}).ui or {}
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width_ratio = type(cfg.dashboard_width) == "number" and cfg.dashboard_width or 0.78
  local height_ratio = type(cfg.dashboard_height) == "number" and cfg.dashboard_height or 0.84
  local width = math.max(72, math.min(math.floor(columns * width_ratio), columns - 4))
  local height = math.max(20, math.min(math.floor(lines * height_ratio), lines - 4))
  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2 - 1)),
    col = math.max(0, math.floor((columns - width) / 2)),
    border = cfg.border or "rounded",
  }
end

local BACKDROP_NAMES = { "picker", "compose", "view", "run" }

-- IMPORTANT: backdrops live under their own state keys (plan_<name>_backdrop)
-- so they do not collide with the float-panel state keys (plan_<name>). The
-- previous design had both sharing `plan_picker` / `plan_compose` / `plan` /
-- `plan_run`, so opening a backdrop silently overwrote the float panel
-- entry, which made every cleanup path ambiguous and left grey backdrops on
-- the screen.
local function backdrop_key(name)
  return "plan_" .. name .. "_backdrop"
end

local function close_backdrop(name)
  local key = backdrop_key(name)
  local backdrop = state.panels[key]
  if backdrop and backdrop.winid and vim.api.nvim_win_is_valid(backdrop.winid) then
    pcall(vim.api.nvim_win_close, backdrop.winid, true)
  end
  state.panels[key] = nil
end

local function close_all_backdrops_except(keep)
  for _, name in ipairs(BACKDROP_NAMES) do
    if name ~= keep then
      close_backdrop(name)
    end
  end
end

-- Hard reset: kill every plan-UI float and every backdrop. Useful when one
-- of them gets stuck and the user wants the screen back.
local function close_all_plan_ui()
  for _, key in ipairs({ "plan_picker", "plan_compose", "plan", "plan_run" }) do
    local panel = state.panels[key]
    if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
      pcall(vim.api.nvim_win_close, panel.winid, true)
    end
    state.panels[key] = nil
  end
  for _, name in ipairs(BACKDROP_NAMES) do
    close_backdrop(name)
  end
  -- Belt-and-suspenders: walk every state.panels.plan_*_backdrop key in case
  -- a previous version stored a backdrop under a different key.
  for key, panel in pairs(state.panels) do
    if type(key) == "string" and key:match("^plan_.*_backdrop$") then
      if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
        pcall(vim.api.nvim_win_close, panel.winid, true)
      end
      state.panels[key] = nil
    end
  end
end

local PLAN_AUGROUP = vim.api.nvim_create_augroup("nvime.plan.cleanup", { clear = true })

-- Defensive backdrop cleanup: if any of our floats closes for any reason
-- (`q`, `:q`, lazy.nvim reload, accidental :wincmd), make sure the
-- corresponding backdrop dies with it. Without this, a stuck backdrop leaves
-- the screen looking dim/grey forever (the bug the user reported on
-- closing the picker).
vim.api.nvim_create_autocmd("WinClosed", {
  group = PLAN_AUGROUP,
  callback = function(args)
    local closed_winid = tonumber(args.match)
    if not closed_winid then
      return
    end
    -- Float panel keys → matching backdrop name
    local mapping = {
      plan_picker = "picker",
      plan_compose = "compose",
      plan = "view",
      plan_run = "run",
    }
    for state_key, backdrop_name in pairs(mapping) do
      local panel = state.panels[state_key]
      if panel and panel.winid == closed_winid then
        state.panels[state_key] = nil
        close_backdrop(backdrop_name)
      end
    end
    -- If the user closed the BACKDROP itself for any reason, also nil it.
    for _, backdrop_name in ipairs(BACKDROP_NAMES) do
      local key = backdrop_key(backdrop_name)
      local backdrop = state.panels[key]
      if backdrop and backdrop.winid == closed_winid then
        state.panels[key] = nil
      end
    end
  end,
})

local function open_backdrop(name)
  local cfg = (state.config or {}).ui or {}
  if cfg.backdrop == false then
    close_backdrop(name)
    return
  end
  local key = backdrop_key(name)
  local existing = state.panels[key]
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
  vim.api.nvim_buf_clear_namespace(bufnr, BACKDROP_NS, 0, -1)
  for row = 0, height - 1 do
    vim.api.nvim_buf_set_extmark(bufnr, BACKDROP_NS, row, 0, {
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
  state.panels[key] = { bufnr = bufnr, winid = winid }
end

local function status_index_hl(status)
  if status == "done" then
    return "NvimePlanStepIndexDone"
  end
  if status == "blocked" then
    return "NvimePlanStepIndexBlocked"
  end
  if status == "in_progress" then
    return "NvimePlanStepIndex"
  end
  return "NvimePlanStepIndexPending"
end

local function progress_bar(plan, width)
  width = width or 36
  local c = counts_for_plan(plan)
  if c.total == 0 then
    return string.rep("░", width), {}
  end
  local function slice(count)
    if c.total == 0 then
      return 0
    end
    return math.floor(count / c.total * width + 0.5)
  end
  local done = slice(c.done)
  local active = slice(c.in_progress)
  local blocked = slice(c.blocked)
  if done + active + blocked > width then
    blocked = math.max(0, width - done - active)
  end
  local pending = math.max(0, width - done - active - blocked)
  -- Solid blocks for everything that has happened (done / active / blocked);
  -- colour alone separates the segments, which reads cleaner than mixing
  -- block shades (█▓▒) that look like dithering. The remaining track stays a
  -- light ░ so the bar's full width — and thus overall progress — is legible.
  local segments = {}
  local filled = {
    { done, "NvimePlanProgressFill" },
    { active, "NvimePlanProgressActive" },
    { blocked, "NvimePlanStepBlocked" },
  }
  for _, seg in ipairs(filled) do
    if seg[1] > 0 then
      segments[#segments + 1] = { string.rep("█", seg[1]), seg[2] }
    end
  end
  if pending > 0 then
    segments[#segments + 1] = { string.rep("░", pending), "NvimePlanProgressTrack" }
  end
  local text = ""
  for _, seg in ipairs(segments) do
    text = text .. seg[1]
  end
  return text, segments
end

local function pad_right(text, width)
  text = text or ""
  local visible = vim.fn.strdisplaywidth(text)
  if visible >= width then
    return text
  end
  return text .. string.rep(" ", width - visible)
end

-- Lead marker for a heading row: the named icon followed by `pad` trailing
-- spaces, or the "▎ " bar fallback when icons are disabled (ui.icon → ""). One
-- place for the glyph-or-bar rule so the plan/picker headers and section
-- headings can't drift apart.
local function glyph_or_bar(name, pad)
  local icon = ui.icon(name)
  return icon ~= "" and (icon .. pad) or "▎ "
end

-- Forward declarations needed by render_plan and friends. Defined later in
-- the file as named-anonymous locals (e.g. `close_picker = function() ... end`).
local install_plan_view_keymaps
local install_picker_keymaps
local refresh_picker
local picker_winid
local close_picker

local function render_plan_lines(plan)
  local lines = {}
  local marks = {} -- { row, hl, line = true } | { row, hl, col_start, col_end, priority? } | { row, virt = true, chunks = {...} }
  local step_index = {} -- step_id -> { first_row, last_row }

  -- Lazy-loaded so plan.lua does not hard-require nvime.render. We use it
  -- for the inline_spans scanner (backticks, **bold**, _em_, [links]) so
  -- prose inside the plan view picks up the same markdown decoration as
  -- the agent scrollback. A nil scanner means we silently fall back to
  -- plain coloring — no behavior change.
  local ok_render, render = pcall(require, "nvime.render")
  local inline_spans_fn = nil
  if ok_render and render and type(render.inline_spans) == "function" then
    inline_spans_fn = render.inline_spans
  end

  local function push(line, hl)
    -- Defensive: nvim_buf_set_lines rejects items containing \n. plan.json
    -- step.intent / step.notes / acceptance.text / etc. can legitimately
    -- contain embedded newlines (the agent encoded them in JSON, decoded
    -- back to literal \n). Without this guard, render_plan crashes any
    -- time the user opens or refreshes the plan view. Replace embedded
    -- newlines with the visible glyph so the line stays single-row but
    -- the user still sees the full content.
    line = tostring(line or ""):gsub("\r", ""):gsub("\n", " ↵ ")
    lines[#lines + 1] = line
    if hl then
      marks[#marks + 1] = { row = #lines - 1, hl = hl, line = true }
    end
    return #lines - 1
  end

  local function mark_range(row, col_start, col_end, hl, priority)
    marks[#marks + 1] = {
      row = row,
      hl = hl,
      col_start = col_start,
      col_end = col_end,
      priority = priority,
    }
  end

  -- Overlay inline-span marks on top of whatever line-level coloring the
  -- caller already pushed. Only scans bytes at/after `start_col` so leading
  -- indent or section glyph never confuses the scanner. inline_spans returns
  -- 1-indexed Lua positions; convert to 0-indexed extmark cols. Higher
  -- priority than the line-level mark so e.g. `code` highlight wins over
  -- the dim italic NvimePlanWhy that was applied to the whole line.
  local function apply_inline(row, line, start_col)
    if not inline_spans_fn or line == nil or line == "" then
      return
    end
    start_col = start_col or 0
    local body = line:sub(start_col + 1)
    if body == "" then
      return
    end
    for _, span in ipairs(inline_spans_fn(body)) do
      mark_range(row, start_col + span[1] - 1, start_col + span[2], span[3], 200)
    end
  end

  local function push_blank()
    push("")
  end

  local function push_rule()
    push("  " .. string.rep("─", 76), "NvimePlanRule")
  end

  -- Section heading like "   WHY", led by a Nerd Font section glyph (falls
  -- back to the "▎" bar glyph when icons are disabled). The whole row carries
  -- the heading colour so the icon reads as part of the section marker.
  local SECTION_ICONS = { WHY = "ask", ACCEPTANCE = "success", FILES = "folder", STEPS = "list" }
  local function push_section(label)
    return push("  " .. glyph_or_bar(SECTION_ICONS[label] or "review", "  ") .. label, "NvimePlanHeading")
  end

  local title = plan.title or plan.id or "(unnamed plan)"
  local status = plan_overall_status(plan)
  local c = counts_for_plan(plan)
  local updated = plan.updated_at or plan.created_at
  local updated_label = updated and ui.relative_time(updated) or "new"

  push_blank()
  -- Header line: " 󰚩  PLAN  0001-audit-prune " led by the brand glyph, with the
  -- id rendered as a badge chip.
  local brand_glyph = glyph_or_bar("brand", " ")
  local id_label = " " .. (plan.id or "?") .. " "
  local prefix = "  " .. brand_glyph .. " PLAN "
  local row = push(prefix .. id_label, "NvimePlanHeading")
  -- Accent the brand glyph (cyan), then the id chip as a badge.
  mark_range(row, 2, 2 + #brand_glyph, "NvimeSection", 250)
  mark_range(row, #prefix, #prefix + #id_label, "NvimePlanBadgeKey")
  -- Title line
  push("  " .. title, "NvimePlanIntent")

  -- Status row with bar
  local status_word = status:gsub("_", " ")
  local bar_text = progress_bar(plan, 36)
  local status_line = string.format(
    "  %s  %s  %s   %d/%d done · updated %s",
    status_icon(status),
    pad_right(status_word, 12),
    bar_text,
    c.done,
    c.total,
    updated_label
  )
  local status_row = push(status_line, status_hl(status))

  -- Continuity badge: "↻ claude · resume" when the plan has a stored
  -- provider session, "○ fresh" when not. Lets the user see at a glance
  -- whether the next step will share architecture context with prior steps.
  do
    local provider_sessions = plan.provider_sessions or {}
    local resume_chunks = {}
    for prov_name, sess_id in pairs(provider_sessions) do
      if sess_id and sess_id ~= "" then
        resume_chunks[#resume_chunks + 1] = (ui.icon("resume") ~= "" and ui.icon("resume") or "~") .. " " .. prov_name
      end
    end
    local continuity_text
    if #resume_chunks > 0 then
      continuity_text = "  session: " .. table.concat(resume_chunks, ", ") .. "  ·  gN to reset"
      push(continuity_text, "NvimePlanFile")
    else
      push("  session: fresh (no resume captured)", "NvimePlanWhy")
    end
  end

  -- Highlight the bar precisely. 4 leading spaces + icon (display 1) + 2 spaces + status_word padded 12 + 2 spaces.
  do
    -- The icon may be a multi-byte glyph; compute its byte length safely.
    local icon = status_icon(status)
    local prefix_text = "  " .. icon .. "  " .. pad_right(status_word, 12) .. "  "
    local bar_byte_start = #prefix_text
    -- color each segment of the bar
    local cursor = bar_byte_start
    local _, segments = progress_bar(plan, 36)
    for _, seg in ipairs(segments) do
      local seg_text, seg_hl = seg[1], seg[2]
      local seg_bytes = #seg_text
      mark_range(status_row, cursor, cursor + seg_bytes, seg_hl)
      cursor = cursor + seg_bytes
    end
  end
  push_blank()
  push_rule()
  push_blank()

  if plan.why and plan.why ~= "" then
    push_section("WHY")
    for _, paragraph in ipairs(vim.split(plan.why, "\n", { plain = true })) do
      local prow = push("      " .. paragraph, "NvimePlanWhy")
      apply_inline(prow, lines[prow + 1], 6)
    end
    push_blank()
  end

  if plan.acceptance and #plan.acceptance > 0 then
    push_section("ACCEPTANCE")
    for _, item in ipairs(plan.acceptance) do
      local itxt = type(item) == "table" and (item.text or "") or tostring(item)
      local istatus = type(item) == "table" and item.status or "pending"
      local arow = push("      " .. status_icon(istatus) .. "  " .. itxt)
      mark_range(arow, 6, 6 + #status_icon(istatus), status_hl(istatus))
      local body_start = 6 + #status_icon(istatus)
      mark_range(arow, body_start, #(lines[arow + 1] or ""), "NvimePlanWhy")
      apply_inline(arow, lines[arow + 1], body_start)
    end
    push_blank()
  end

  if plan.files_estimated and #plan.files_estimated > 0 then
    push_section("FILES")
    for _, file in ipairs(plan.files_estimated) do
      push("      " .. tostring(file), "NvimePlanFile")
    end
    push_blank()
  end

  push_section("STEPS")
  push_blank()

  -- Helper: meta-style row with a labelled prefix ("tests · ", "notes · ",
  -- "deps "). Highlights the indent + label distinctly from the body and
  -- runs inline_spans on the body so backticked code/identifiers light up.
  local META_INDENT = "         " -- 9 spaces
  local function push_meta(label, body)
    local prefix = META_INDENT .. label
    local line = prefix .. body
    local mrow = push(line, "NvimePlanMeta")
    mark_range(mrow, #META_INDENT, #prefix, "NvimePlanMetaLabel", 240)
    apply_inline(mrow, line, #prefix)
    return mrow
  end

  for _, step in ipairs(plan.steps or {}) do
    local s = step_status(step)
    local index_label = string.format(" %d ", step.id or 0)
    local intent_text = step.intent or "(no intent)"
    local first_line = "  " .. status_icon(s) .. "  " .. index_label .. "  " .. intent_text
    local first = push(first_line)
    -- Highlight the icon
    local icon = status_icon(s)
    mark_range(first, 2, 2 + #icon, status_hl(s))
    -- Highlight the index badge
    local idx_start = 2 + #icon + 2 -- "  <icon>  "
    mark_range(first, idx_start, idx_start + #index_label, status_index_hl(s))
    -- Highlight the intent
    local intent_start = idx_start + #index_label + 2
    mark_range(first, intent_start, #first_line, "NvimePlanIntent")
    -- Inline spans (`code`, **bold**, _em_, [link](url)) on the intent
    -- body. Higher priority overlay so e.g. backticked code wins over
    -- the bold NvimePlanIntent. Stops at the start of the buffer line so
    -- nothing misfires on the leading icon/badge.
    apply_inline(first, first_line, intent_start)

    -- File and range. Distinguish the file path (clickable-feeling color)
    -- from the range label (line-number-y dim italic) so the eye can find
    -- the file fast even on a dense plan.
    local file_text = step.file or "?"
    local range_text = range_label(step)
    local file_line = META_INDENT .. file_text .. "  " .. range_text
    local file_row = push(file_line)
    local file_start = #META_INDENT
    local file_end = file_start + #file_text
    local range_start = file_end + 2
    local range_end = range_start + #range_text
    mark_range(file_row, file_start, file_end, "NvimePlanFile")
    mark_range(file_row, range_start, range_end, "NvimePlanRange")

    if step.depends_on and #step.depends_on > 0 then
      local labels = {}
      for _, dep in ipairs(step.depends_on) do
        labels[#labels + 1] = "#" .. tostring(dep)
      end
      push_meta("deps ", table.concat(labels, " "))
    end
    if step.tests and #step.tests > 0 then
      push_meta("tests · ", table.concat(step.tests, " ; "))
    end
    if step.notes and step.notes ~= "" then
      for _, line in ipairs(vim.split(step.notes, "\n", { plain = true })) do
        push_meta("notes · ", line)
      end
    end
    local last = #lines - 1
    step_index[step.id or 0] = { first = first, last = last }
    push_blank()
  end

  push_rule()
  push("    <CR> exec   gE edit-then-exec   gx done   gp pending   gB blocked   gT tests", "NvimePlanFooter")
  push("    ]s [s navigate       gA run next pending   gW write test   gd refine   gr replan", "NvimePlanFooter")
  push("    gN reset session     o open file           c copy intent   ? help     q close", "NvimePlanFooter")
  push_blank()

  return lines, marks, step_index
end

local function configure_window(winid)
  -- Shared panel chrome (wrap on for long plan prose; cursorline on for the
  -- selected step/row; signcolumn pads the left edge into a card).
  ui.configure_panel_window(winid, { wrap = true, cursorline = true })
end

local function open_plan_window(bufnr, title)
  local existing = state.panels.plan
  local dim = dimensions()
  local brand = ui.icon("brand")
  local config = {
    relative = "editor",
    width = dim.width,
    height = dim.height,
    row = dim.row,
    col = dim.col,
    style = "minimal",
    border = dim.border,
    title = " " .. brand .. "  " .. title .. " ",
    title_pos = "center",
    footer = " <CR> exec · gx done · ]s/[s nav · gd discuss · gr replan · q close ",
    footer_pos = "center",
    zindex = 54,
    focusable = true,
  }
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_win_set_buf(existing.winid, bufnr)
    vim.api.nvim_win_set_config(existing.winid, config)
    configure_window(existing.winid)
    return existing.winid
  end
  local winid = vim.api.nvim_open_win(bufnr, true, config)
  configure_window(winid)
  state.panels.plan = { bufnr = bufnr, winid = winid }
  return winid
end

local function step_at_cursor(step_index)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for id, range in pairs(step_index or {}) do
    if row >= range.first + 1 and row <= range.last + 1 then
      return id
    end
  end
  return nil
end

local function set_locked(bufnr, locked)
  vim.bo[bufnr].readonly = locked
  vim.bo[bufnr].modifiable = not locked
end

local function render_plan(plan, opts)
  opts = opts or {}
  local bufnr = find_buffer(buffer_name_for(plan.id))
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, buffer_name_for(plan.id))
  end
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "nvimeplan"

  local lines, marks, step_index = render_plan_lines(plan)
  set_locked(bufnr, false)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, PLAN_NS, 0, -1)
  ui.ensure_highlights()
  for _, mark in ipairs(marks) do
    local line = lines[mark.row + 1] or ""
    if mark.line then
      vim.api.nvim_buf_set_extmark(bufnr, PLAN_NS, mark.row, 0, {
        end_col = #line,
        hl_group = mark.hl,
        hl_eol = true,
      })
    else
      local col_start = math.max(0, math.min(mark.col_start or 0, #line))
      local col_end = math.max(col_start, math.min(mark.col_end or #line, #line))
      if col_end > col_start then
        local extmark_opts = {
          end_col = col_end,
          hl_group = mark.hl,
        }
        if mark.priority then
          extmark_opts.priority = mark.priority
        end
        vim.api.nvim_buf_set_extmark(bufnr, PLAN_NS, mark.row, col_start, extmark_opts)
      end
    end
  end
  set_locked(bufnr, true)

  vim.b[bufnr].nvime_plan_id = plan.id
  vim.b[bufnr].nvime_plan_step_index = step_index

  local winid
  if opts.open ~= false then
    -- Close any stacked plan UI floats first so we don't fight zindex order.
    close_picker()
    local compose_panel = state.panels.plan_compose
    if compose_panel and compose_panel.winid and vim.api.nvim_win_is_valid(compose_panel.winid) then
      pcall(vim.api.nvim_win_close, compose_panel.winid, true)
      state.panels.plan_compose = nil
    end
    close_all_backdrops_except("view")
    open_backdrop("view")
    winid = open_plan_window(bufnr, "nvime plan · " .. (plan.title or plan.id))
    if winid then
      pcall(vim.api.nvim_set_current_win, winid)
    end
  end

  state.plan.last_opened = plan.id
  return bufnr, winid, step_index
end

local function close_plan_view()
  local panel = state.panels.plan
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_close, panel.winid, true)
  end
  state.panels.plan = nil
  close_backdrop("view")
end

-- (forward declarations moved earlier, see top of file)

-- ============================================================================
-- Step operations
-- ============================================================================

-- Append one "Step N executed @ <iso>" section to plan.md. Called whenever a
-- step transitions pending → done (or any non-done → done). Captures the
-- patch worker's rationale, critic verdict, and test-runner tail when the
-- caller passes them in `ctx`. Without ctx we still write a minimal entry
-- so a manual `gx` flip leaves a paper trail. plan.md becomes the
-- after-the-fact narrative of what each step actually did.
local function append_step_changelog(plan, step, ctx)
  ctx = ctx or {}
  local md_path = plan_md_path(plan.id)
  ensure_dir(plan_dir_for(plan.id))
  local existing = ""
  if vim.fn.filereadable(md_path) == 1 then
    local ok, lines = pcall(vim.fn.readfile, md_path)
    if ok and lines then
      existing = table.concat(lines, "\n")
    end
  end

  -- Initialize a top-of-file changelog header on the first append per plan.
  if not existing:find("## nvime execution log", 1, true) then
    existing = (existing ~= "" and (existing .. "\n\n") or "")
      .. "## nvime execution log\n\n"
      .. "Each entry is appended automatically when a step transitions to `done`.\n"
      .. "Records what was applied, the rationale, the critic verdict, and the\n"
      .. "test output. This is the after-the-fact narrative — the body above is\n"
      .. "the architect's plan; the body below is what nvime + you actually did.\n"
  end

  local iso = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local section = { "" }
  section[#section + 1] = string.format("### Step %s executed @ %s", tostring(step.id or "?"), iso)
  section[#section + 1] = ""
  section[#section + 1] = string.format("- Intent: %s", (step.intent or "(none)"):gsub("\n", " ↵ "))
  if step.file then
    local where = step.file
    if type(step.range) == "table" and step.range.line1 then
      where = where .. " (L" .. tostring(step.range.line1) .. "-" .. tostring(step.range.line2 or "?") .. ")"
    elseif step.range == "new" then
      where = where .. " (new file)"
    end
    section[#section + 1] = string.format("- File: %s", where)
  end
  section[#section + 1] = string.format("- Provider: %s", ctx.provider or "?")
  if ctx.rationale and ctx.rationale ~= "" then
    section[#section + 1] = string.format("- Rationale: %s", ctx.rationale)
  end
  if type(ctx.verdict) == "table" and ctx.verdict.decision then
    section[#section + 1] =
      string.format("- Critic: **%s** — %s", ctx.verdict.decision, ctx.verdict.justification or "")
  elseif ctx.verdict_pending then
    section[#section + 1] = "- Critic: (verdict pending at done-time)"
  end
  if ctx.accepted and ctx.total then
    section[#section + 1] = string.format("- Diff blocks: %d/%d accepted", ctx.accepted, ctx.total)
  end
  if ctx.forced and ctx.forced > 0 then
    section[#section + 1] = string.format("- Force-accepts: **%d** (review!)", ctx.forced)
  end
  if ctx.tests_cmd and ctx.tests_cmd ~= "" then
    section[#section + 1] = string.format("- Tests: `%s` → %s", ctx.tests_cmd, ctx.tests_pass and "pass" or "fail")
    if ctx.tests_tail and ctx.tests_tail ~= "" then
      section[#section + 1] = ""
      section[#section + 1] = "  ```"
      for _, line in ipairs(vim.split(ctx.tests_tail, "\n", { plain = true })) do
        section[#section + 1] = "  " .. line
      end
      section[#section + 1] = "  ```"
    end
  end
  if ctx.manual then
    section[#section + 1] = "- Source: manual `gx` mark-done"
  end

  local new_body = existing .. "\n" .. table.concat(section, "\n") .. "\n"
  local fd, err = io.open(md_path, "w")
  if not fd then
    vim.notify("nvime plan: could not append plan.md changelog: " .. tostring(err), vim.log.levels.WARN)
    return
  end
  pcall(function()
    fd:write(new_body)
  end)
  pcall(function()
    fd:close()
  end)
end

local function set_step_status(plan_id, step_id, new_status, ctx)
  if not STATUS_ORDER[new_status] then
    return false, "invalid status: " .. tostring(new_status)
  end
  local plan = M.get(plan_id)
  if not plan then
    return false, "plan not found: " .. tostring(plan_id)
  end
  local step = find_step(plan, step_id)
  if not step then
    return false, "step not found: " .. tostring(step_id)
  end
  local prior_status = step.status
  step.status = new_status
  if not persist_plan(plan) then
    return false, "could not write plan"
  end
  audit.write({
    event = "plan_step_status",
    plan_id = plan.id,
    step_id = step.id,
    status = new_status,
  })
  -- Living changelog: any time a step crosses into "done", append a section
  -- to plan.md. ctx (rationale/verdict/tests) is only present from the
  -- post-execute path; manual `gx` marks pass nothing and we record a
  -- minimal entry so plan.md still reflects the transition.
  if new_status == "done" and prior_status ~= "done" then
    append_step_changelog(plan, step, ctx or { manual = true })
  end
  return true
end

M.set_step_status = set_step_status

function M.delete(plan_id)
  local plan = M.get(plan_id)
  if not plan then
    return false
  end
  local dir = plan_dir_for(plan_id)
  pcall(vim.fn.delete, dir, "rf")
  audit.write({ event = "plan_deleted", plan_id = plan_id })
  M.refresh()
  save_index(M.plans())
  return true
end

-- Extract identifier-shaped tokens from a step intent, prioritizing those
-- in `backticks` (which the plan author prompt asks for as code refs) and
-- falling back to snake_case / CamelCase identifiers ≥ 4 chars. Used as
-- the symbol-search fallback when a step has no range_anchor (e.g. plans
-- authored before range_anchor existed) and the recorded line range is
-- stale.
local function extract_intent_symbols(intent)
  if type(intent) ~= "string" or intent == "" then
    return {}
  end
  local out = {}
  local seen = {}
  local function push(sym)
    if sym and #sym >= 3 and not seen[sym] then
      seen[sym] = true
      out[#out + 1] = sym
    end
  end
  for sym in intent:gmatch("`([%w_][%w_]*)`") do
    push(sym)
  end
  -- Light fallback: any 4+ char snake_case or CamelCase identifier referenced
  -- bare in the intent body. Skip very generic words.
  local generic = {
    line = true,
    lines = true,
    range = true,
    file = true,
    code = true,
    test = true,
    tests = true,
    plan = true,
    step = true,
    steps = true,
    field = true,
    fields = true,
    value = true,
    values = true,
    with = true,
    today = true,
    when = true,
    here = true,
    then_ = true,
  }
  for sym in intent:gmatch("([%w_][%w_]+)") do
    if #sym >= 4 and (sym:find("_") or sym:find("[A-Z]")) and not generic[sym:lower()] then
      push(sym)
    end
  end
  return out
end

local function search_by_symbols(buf_lines, symbols)
  if not symbols or #symbols == 0 then
    return nil, 0
  end
  local best_line, best_score = nil, 0
  for line_no, line in ipairs(buf_lines) do
    local score = 0
    for _, sym in ipairs(symbols) do
      if line:find(sym, 1, true) then
        local extra = 0
        -- Function definitions / declarations are stronger evidence than
        -- bare references. Same for top-level local declarations.
        if line:find("function%s+" .. sym .. "%(") or line:find("function%s+[%w_%.:]+%." .. sym .. "%(") then
          extra = extra + 3
        end
        if line:find("local%s+function%s+" .. sym) then
          extra = extra + 3
        end
        if line:find("local%s+" .. sym) or line:find("^" .. sym .. "%s*=") then
          extra = extra + 2
        end
        score = score + 1 + extra
      end
    end
    if score > best_score then
      best_score = score
      best_line = line_no
    end
  end
  return best_line, best_score
end

-- Re-anchor a step's recorded line range against the current file content.
-- Order of attempts:
--   1. range_anchor matches at the recorded line1 (cheap fast path).
--   2. range_anchor matches elsewhere in the file (drift correction).
--   3. No anchor / anchor missing in file: extract symbols from `intent`
--      and use the highest-scoring line as a guess (helps OLD plans
--      authored before range_anchor existed, where line numbers may be
--      off by hundreds of lines).
--   4. Last resort: clamp the recorded range as-is, with a notice.
-- Returns (line1, line2, notice, confidence). confidence is one of:
--   "exact"     anchor matched at the recorded line — trust it.
--   "relocated" anchor matched at exactly one OTHER place — drift corrected.
--   "symbol"    located via tree-sitter symbol / intent-symbol search.
--   "ambiguous" anchor matched MULTIPLE places — best guess, low confidence.
--   "stale"     nothing matched — recorded range used as-is, low confidence.
-- `opts.bufnr` (optional) enables the tree-sitter enclosing-symbol fallback.
local function reanchor_range(buf_lines, recorded_line1, recorded_line2, anchor, intent, opts)
  opts = opts or {}
  local total = #buf_lines
  local function clamp_recorded(notice, confidence)
    local l1 = math.max(1, math.min(recorded_line1 or 1, total))
    local l2 = math.max(l1, math.min(recorded_line2 or l1, total))
    return l1, l2, notice, confidence or "stale"
  end

  local function capped_span(found)
    local span = (recorded_line2 or recorded_line1 or found) - (recorded_line1 or found)
    span = math.max(span, 0)
    -- Cap the span at 40 lines so a wildly drifted range doesn't ship a huge
    -- unfocused selection to the patch worker.
    if span > 40 then
      span = 40
    end
    return span
  end

  -- Tree-sitter enclosing-symbol fallback: if the intent names a symbol that
  -- tree-sitter can locate UNIQUELY in the current buffer, use that node's
  -- range. More robust than line matching when the file was restructured.
  local function ts_fallback(reason)
    if not opts.bufnr then
      return nil
    end
    local symbols = extract_intent_symbols(intent or "")
    if #symbols == 0 then
      return nil
    end
    local ok, nodes = pcall(function()
      return require("nvime.treesitter").walk_symbols(opts.bufnr)
    end)
    if not ok or type(nodes) ~= "table" then
      return nil
    end
    local want = {}
    for _, s in ipairs(symbols) do
      want[s] = true
    end
    local match, count = nil, 0
    for _, node in ipairs(nodes) do
      if node.name and want[node.name] then
        count = count + 1
        match = match or node
      end
    end
    if match and count == 1 then
      local notice = string.format(
        "step range drifted (%s): tree-sitter located `%s` at lines %d-%d (recorded was %d-%d)",
        reason,
        match.name,
        match.line_start,
        match.line_end,
        recorded_line1 or -1,
        recorded_line2 or -1
      )
      return math.max(1, match.line_start), math.min(total, match.line_end), notice, "symbol"
    end
    return nil
  end

  local function symbol_fallback(reason)
    local t1, t2, tnotice, tconf = ts_fallback(reason)
    if t1 then
      return t1, t2, tnotice, tconf
    end
    local symbols = extract_intent_symbols(intent or "")
    local found, score = search_by_symbols(buf_lines, symbols)
    if found and score >= 1 then
      local span = capped_span(found)
      local notice = string.format(
        "step range drifted (%s): symbols matched line %d (recorded was %d-%d)",
        reason,
        found,
        recorded_line1 or -1,
        recorded_line2 or -1
      )
      return found, math.min(total, found + span), notice, "symbol"
    end
    return nil
  end

  if not anchor or anchor == "" then
    local fl1, fl2, fnotice, fconf = symbol_fallback("no range_anchor")
    if fl1 then
      return fl1, fl2, fnotice, fconf
    end
    return clamp_recorded(nil, "stale")
  end

  local anchor_lines = vim.split(anchor, "\n", { plain = true })
  while #anchor_lines > 0 and anchor_lines[#anchor_lines]:match("^%s*$") do
    table.remove(anchor_lines)
  end
  if #anchor_lines == 0 then
    local fl1, fl2, fnotice, fconf = symbol_fallback("empty range_anchor")
    if fl1 then
      return fl1, fl2, fnotice, fconf
    end
    return clamp_recorded(nil, "stale")
  end

  local function matches_at(start)
    if start < 1 or start + #anchor_lines - 1 > total then
      return false
    end
    for i = 1, #anchor_lines do
      if buf_lines[start + i - 1] ~= anchor_lines[i] then
        return false
      end
    end
    return true
  end

  if recorded_line1 and matches_at(recorded_line1) then
    local span = (recorded_line2 or recorded_line1) - recorded_line1
    return recorded_line1, math.min(total, recorded_line1 + span), nil, "exact"
  end

  -- Collect every match so we can tell a clean relocation from an ambiguous one.
  local matches = {}
  for start = 1, total - #anchor_lines + 1 do
    if matches_at(start) then
      matches[#matches + 1] = start
    end
  end
  if #matches > 0 then
    local best = matches[1]
    for _, start in ipairs(matches) do
      if math.abs(start - (recorded_line1 or 1)) < math.abs(best - (recorded_line1 or 1)) then
        best = start
      end
    end
    local span = (recorded_line2 or recorded_line1 or best) - (recorded_line1 or best)
    local new_line2 = math.min(total, best + math.max(0, span))
    if #matches == 1 then
      local notice = nil
      if best ~= recorded_line1 then
        notice = string.format("step range drifted: anchor was at line %d, now at line %d", recorded_line1 or -1, best)
      end
      return best, new_line2, notice, "relocated"
    end
    local notice = string.format(
      "step anchor is ambiguous: %d matches; using the nearest at line %d (recorded was %d)",
      #matches,
      best,
      recorded_line1 or -1
    )
    return best, new_line2, notice, "ambiguous"
  end

  -- Anchor exists but didn't match; try symbols/tree-sitter before giving up.
  local fl1, fl2, fnotice, fconf = symbol_fallback("range_anchor not found in file")
  if fl1 then
    return fl1, fl2, fnotice, fconf
  end
  return clamp_recorded("step anchor not found in file; using recorded range as-is", "stale")
end

M._reanchor_range = reanchor_range -- exposed for tests
M._extract_intent_symbols = extract_intent_symbols

-- Build an old-line -> new-line map from two versions of a file using
-- vim.diff hunk indices. Lines before any change map to themselves; lines
-- after a change shift by the net (added - removed); lines that fall inside a
-- changed region anchor to the new region's start (best effort).
local function build_line_map(old_lines, new_lines)
  local a = table.concat(old_lines or {}, "\n")
  local b = table.concat(new_lines or {}, "\n")
  local ok, hunks = pcall(vim.diff, a, b, { result_type = "indices" })
  if not ok or type(hunks) ~= "table" then
    hunks = {}
  end
  return function(line)
    if not line then
      return line
    end
    local delta = 0
    for _, h in ipairs(hunks) do
      local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
      if ca == 0 then
        -- Pure insertion after old line `sa`: lines below it shift down.
        if line > sa then
          delta = delta + cb
        end
      else
        local old_end = sa + ca - 1
        if line > old_end then
          delta = delta + (cb - ca)
        elseif line >= sa then
          -- Inside the changed region — anchor to the new region start.
          return math.max(1, sb)
        end
      end
    end
    return line + delta
  end
end

-- Live range-rebasing: after a step's accepted edit changes `file` from
-- `old_lines` to `new_lines`, shift the recorded line range of every other
-- not-yet-done step targeting the same file so later steps stay anchored to
-- the right lines instead of drifting and failing. Symmetric — rollback calls
-- it with old/new swapped to undo the shift.
local function rebase_pending_ranges(plan, file, old_lines, new_lines, current_step_id)
  if not plan or not file or not old_lines or not new_lines then
    return false
  end
  local map = build_line_map(old_lines, new_lines)
  local new_total = math.max(1, #new_lines)
  local changed = false
  for _, s in ipairs(plan.steps or {}) do
    if s.id ~= current_step_id and s.file == file and type(s.range) == "table" and step_status(s) ~= "done" then
      local l1 = tonumber(s.range.line1 or s.range[1])
      local l2 = tonumber(s.range.line2 or s.range[2])
      if l1 and l2 then
        local n1 = math.max(1, math.min(map(l1), new_total))
        local n2 = math.max(n1, math.min(map(l2), new_total))
        if n1 ~= l1 or n2 ~= l2 then
          s.range.line1 = n1
          s.range.line2 = n2
          if s.range[1] ~= nil then
            s.range[1] = n1
          end
          if s.range[2] ~= nil then
            s.range[2] = n2
          end
          changed = true
        end
      end
    end
  end
  if changed then
    persist_plan(plan)
  end
  return changed
end

M._build_line_map = build_line_map -- exposed for tests
M._rebase_pending_ranges = rebase_pending_ranges

local function open_step_target(plan, step)
  local file = step.file
  if not file or file == "" then
    return false, "step has no file"
  end
  local root = git.root() or vim.fn.getcwd()
  local abs = file
  if abs:sub(1, 1) ~= "/" then
    abs = root .. "/" .. file
  end
  local range = step.range
  if range == "new" or range == nil then
    ensure_dir(vim.fn.fnamemodify(abs, ":h"))
    if vim.fn.filereadable(abs) ~= 1 then
      vim.fn.writefile({}, abs)
    end
  end

  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  local bufnr = vim.api.nvim_get_current_buf()
  local total_lines = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local line1, line2
  local anchor_confidence, anchor_notice = "exact", nil
  if range == "new" or range == nil then
    line1, line2 = 1, total_lines
  elseif type(range) == "table" then
    local recorded_l1 = clamp_int(range.line1 or range[1], 1)
    local recorded_l2 = clamp_int(range.line2 or range[2], recorded_l1)
    -- Re-anchor against the current file content if the step has an anchor.
    -- Lines drift when earlier steps modify the same file; without re-
    -- anchoring, the patch worker refuses because the recorded range no
    -- longer covers the target content.
    local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    line1, line2, anchor_notice, anchor_confidence =
      reanchor_range(buf_lines, recorded_l1, recorded_l2, step.range_anchor, step.intent, { bufnr = bufnr })
    if anchor_notice then
      vim.notify("nvime plan: " .. anchor_notice, vim.log.levels.INFO)
    end
  else
    line1, line2 = 1, total_lines
  end
  vim.api.nvim_win_set_cursor(0, { line1, 0 })
  return true,
    {
      bufnr = bufnr,
      line1 = line1,
      line2 = line2,
      col1 = 0,
      col2 = 0,
      path = file,
      -- ask.lua / edit.lua format the prompt header with selection.source;
      -- without this the build_prompt path crashes with "concatenate field
      -- 'source' (a nil value)".
      source = "plan-step",
      -- Drift-resolution metadata; execute_step gates on low confidence.
      anchor_confidence = anchor_confidence or "exact",
      anchor_notice = anchor_notice,
    }
end

local function plan_context_block(plan, step, _char_budget)
  -- No truncation. The plan author writes deliberate per-step context; we
  -- forward it to the patch worker verbatim. claude/codex both have plenty
  -- of context window, and a half-sentence ending in "..." (the previous
  -- 320-char cap) is strictly worse than a long line.
  local steps = plan.steps or {}
  local total = #steps
  local position = string.format("step %s/%d", tostring(step.id or "?"), total)
  local intent = step.intent or "(no intent)"

  local lines = {
    "Plan context (informational; the actual change is bounded by the selected range):",
    string.format("- Plan: %s — %s", plan.id or "?", plan.title or ""),
    "- " .. position .. " (full instruction):",
    "    " .. intent,
  }
  if plan.why and plan.why ~= "" then
    lines[#lines + 1] = "- Why:"
    for _, paragraph in ipairs(vim.split(plan.why, "\n", { plain = true })) do
      lines[#lines + 1] = "    " .. paragraph
    end
  end
  if step.notes and step.notes ~= "" then
    lines[#lines + 1] = "- Step notes:"
    for _, paragraph in ipairs(vim.split(step.notes, "\n", { plain = true })) do
      lines[#lines + 1] = "    " .. paragraph
    end
  end
  -- Include the intents of every step in the current step's transitive
  -- depends_on chain. Plan-execute runs each step as an independent
  -- edit-lane call, so without this a test step cannot see what API its
  -- implementation step pinned and the two can drift (e.g. the test
  -- asserts a different jitter formula than the implementation uses).
  if type(step.depends_on) == "table" and #step.depends_on > 0 then
    local by_id = {}
    for _, candidate in ipairs(steps) do
      if type(candidate) == "table" and candidate.id ~= nil then
        by_id[tostring(candidate.id)] = candidate
      end
    end
    local visited, ordered = {}, {}
    local function collect(dep_id)
      local key = tostring(dep_id)
      if visited[key] then
        return
      end
      visited[key] = true
      local dep = by_id[key]
      if not dep then
        return
      end
      for _, nested in ipairs(dep.depends_on or {}) do
        collect(nested)
      end
      ordered[#ordered + 1] = dep
    end
    for _, dep_id in ipairs(step.depends_on) do
      collect(dep_id)
    end
    if #ordered > 0 then
      lines[#lines + 1] = "- Dependency-step intents (the contract this step must agree with):"
      for _, dep in ipairs(ordered) do
        lines[#lines + 1] = string.format("    [step %s] %s", tostring(dep.id or "?"), dep.intent or "(no intent)")
        if dep.notes and dep.notes ~= "" then
          for _, paragraph in ipairs(vim.split(dep.notes, "\n", { plain = true })) do
            lines[#lines + 1] = "      notes: " .. paragraph
          end
        end
      end
    end
  end
  -- Include the actual acceptance texts (not just a count) so the patch
  -- worker knows what success looks like at the plan level.
  local acceptance_lines = {}
  for _, item in ipairs(plan.acceptance or {}) do
    local txt = type(item) == "table" and (item.text or "") or tostring(item)
    if txt ~= "" then
      acceptance_lines[#acceptance_lines + 1] = "    - " .. txt
    end
  end
  if #acceptance_lines > 0 then
    lines[#lines + 1] = "- Plan-level acceptance:"
    vim.list_extend(lines, acceptance_lines)
  end
  return table.concat(lines, "\n")
end

-- Detect the project's primary test file so the test scaffolder has a
-- sensible default. Falls back to nil if the user must pick. Covers Lua,
-- Python, Go, JS/TS, Rust, Zig, C/C++, Java/Kotlin conventions.
local function detect_test_file()
  local cfg = plan_config()
  if cfg.test_file and cfg.test_file ~= "" then
    return cfg.test_file
  end
  local root = git.root() or vim.fn.getcwd()
  local candidates = {
    -- Lua / Neovim
    "tests/headless_spec.lua",
    "tests/spec.lua",
    "tests/test_spec.lua",
    "test/test.lua",
    "spec/spec.lua",
    -- Python
    "tests/__init__.py",
    "tests/test.py",
    "tests/test_main.py",
    "tests/test_basic.py",
    "test_basic.py",
    -- Go
    "test/test.go",
    "internal/test_test.go",
    -- TypeScript / JavaScript
    "tests/integration.test.ts",
    "tests/index.test.ts",
    "tests/index.test.js",
    "src/__tests__/index.test.ts",
    "src/__tests__/index.test.js",
    "test/index.test.js",
    -- Rust
    "tests/integration_test.rs",
    "tests/it.rs",
    "tests/main.rs",
    -- Zig
    "tests/main_test.zig",
    "src/main_test.zig",
    "test.zig",
    -- C / C++
    "tests/test_main.c",
    "tests/test_main.cpp",
    "test/test_main.c",
    "test/test_main.cpp",
    -- Java / Kotlin
    "src/test/java/AppTest.java",
    "src/test/kotlin/AppTest.kt",
  }
  for _, rel in ipairs(candidates) do
    if vim.fn.filereadable(root .. "/" .. rel) == 1 then
      return rel
    end
  end
  return nil
end

-- Detect the project's preferred test runner from common project markers.
-- Returned as a single shell command suitable to be put into step.tests.
-- opts.configured — explicit override; returned verbatim when non-empty.
-- opts.root       — search root; defaults to git root or cwd.
-- opts.related    — related test paths; used for the .py extension fallback.
local function detect_test_runner(opts)
  opts = opts or {}
  local configured = opts.configured
  if not configured then
    local cfg = plan_config()
    if cfg.test_runner and cfg.test_runner ~= "" then
      configured = cfg.test_runner
    end
  end
  if configured and configured ~= "" then
    return configured
  end
  local root = opts.root or git.root() or vim.fn.getcwd()
  local function exists(rel)
    return vim.fn.filereadable(root .. "/" .. rel) == 1 or vim.fn.isdirectory(root .. "/" .. rel) == 1
  end
  if exists("scripts/test") then
    return "./scripts/test"
  end
  if exists("Cargo.toml") then
    return "cargo test --quiet"
  end
  if exists("build.zig") then
    return "zig build test"
  end
  if exists("go.mod") then
    return "go test ./..."
  end
  if exists("pyproject.toml") or exists("pytest.ini") or exists("setup.py") then
    return "pytest -q"
  end
  local python_tests = vim.fn.globpath(root, "test_*.py", false, true)
  if #python_tests == 0 then
    python_tests = vim.fn.globpath(root, "tests/test*.py", false, true)
  end
  if #python_tests > 0 then
    return "python -m unittest -q"
  end
  if exists("package.json") then
    return "npm test --silent"
  end
  if exists("pom.xml") then
    return "mvn -q test"
  end
  if exists("build.gradle") or exists("build.gradle.kts") then
    return "gradle -q test"
  end
  if exists("CMakeLists.txt") then
    return "ctest --output-on-failure"
  end
  if exists("Makefile") then
    return "make test"
  end
  if opts.related then
    for _, rel in ipairs(opts.related) do
      if rel:match("%.py$") then
        return "python -m unittest -q"
      end
    end
  end
  return nil
end

M.detect_test_file = detect_test_file
M.detect_test_runner = detect_test_runner

local function build_test_intent(plan, step, target_file)
  local lines = {
    "Add a regression test that exercises the change made by step "
      .. tostring(step.id)
      .. " of plan "
      .. plan.id
      .. ".",
    "",
    "Step intent (verbatim):",
    step.intent or "(no intent)",
    "",
    "The change was applied to " .. (step.file or "?") .. " " .. (step.range == "new" and "(new file)" or (type(
      step.range
    ) == "table" and ("L" .. (step.range.line1 or "?") .. "-" .. (step.range.line2 or "?")) or "?")) .. ".",
    "",
    "Required test discipline:",
    "  1. The test MUST fail without the step's change and pass after it.",
    "  2. Append to the END of the selected range; do not rewrite existing tests.",
    "  3. Use the same harness pattern that surrounding tests in this file use.",
    "  4. Keep the test self-contained; create temp files / fixtures as needed.",
    "  5. Name the test clearly so future readers understand what it guards.",
    "",
    "Target file: " .. target_file,
  }
  return table.concat(lines, "\n")
end

function M.add_test_for_step(plan_id, step_id, opts)
  opts = opts or {}
  local plan = M.get(plan_id)
  if not plan then
    vim.notify("nvime: unknown plan " .. tostring(plan_id), vim.log.levels.ERROR)
    return false
  end
  local step = find_step(plan, step_id)
  if not step then
    vim.notify("nvime: unknown step " .. tostring(step_id), vim.log.levels.ERROR)
    return false
  end

  local target_file = opts.test_file or detect_test_file()
  if not target_file then
    vim.notify(
      "nvime: could not auto-detect a test file. Set plan.test_file in your nvime config or pass --file=...",
      vim.log.levels.ERROR
    )
    return false
  end

  local root = git.root() or vim.fn.getcwd()
  local abs = target_file
  if abs:sub(1, 1) ~= "/" then
    abs = root .. "/" .. target_file
  end
  if vim.fn.filereadable(abs) ~= 1 then
    vim.notify("nvime: test file not found: " .. abs, vim.log.levels.ERROR)
    return false
  end

  close_plan_view()
  vim.cmd("edit " .. vim.fn.fnameescape(abs))
  local bufnr = vim.api.nvim_get_current_buf()
  local total = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  local first = math.max(1, total - 5)
  vim.api.nvim_win_set_cursor(0, { first, 0 })

  local selection = {
    bufnr = bufnr,
    line1 = first,
    line2 = total,
    col1 = 0,
    col2 = 0,
    path = target_file,
    source = "plan-test-scaffold",
  }

  audit.write({
    event = "plan_step_test_scaffold",
    plan_id = plan.id,
    step_id = step.id,
    test_file = target_file,
  })

  -- On accept, append the file path to step.tests as a default verifier.
  local on_resolved = function(summary)
    if (summary.accepted or 0) == 0 then
      vim.schedule(function()
        vim.notify(
          "nvime plan: test scaffold rejected; step " .. tostring(step.id) .. " still has no test",
          vim.log.levels.WARN
        )
      end)
      return
    end
    vim.schedule(function()
      -- Update the plan's step.tests so future re-runs of the step exercise
      -- the new test (if not already covered by an existing entry).
      local fresh = M.get(plan.id)
      if not fresh then
        return
      end
      local fresh_step = find_step(fresh, step.id)
      if not fresh_step then
        return
      end
      fresh_step.tests = fresh_step.tests or {}
      local default_runner = detect_test_runner() or "./scripts/test"
      local already = false
      for _, t in ipairs(fresh_step.tests) do
        if t == default_runner then
          already = true
          break
        end
      end
      if not already then
        table.insert(fresh_step.tests, default_runner)
      end
      persist_plan(fresh)
      vim.notify(
        "nvime plan: regression test added to "
          .. target_file
          .. "; step "
          .. tostring(step.id)
          .. ".tests now has "
          .. #fresh_step.tests
          .. " entr"
          .. (#fresh_step.tests == 1 and "y" or "ies"),
        vim.log.levels.INFO
      )
    end)
  end

  require("nvime.edit").start({
    selection = selection,
    intent = build_test_intent(plan, step, target_file),
    line1 = selection.line1,
    line2 = selection.line2,
    range = 2,
    provider = opts.provider,
    force_edit = true,
    on_resolved = on_resolved,
  })
  return true
end

-- Clear the plan's stored provider session id so the next step (or the
-- next plan_author refinement) starts a fresh conversation. Use this when
-- the conversation has accumulated too much context, when the model has
-- gone off-track, or simply when you want a clean slate. If `provider` is
-- nil, clears all providers' sessions for the plan.
function M.reset_session(plan_id, provider)
  local plan = M.get(plan_id)
  if not plan then
    vim.notify("nvime: unknown plan " .. tostring(plan_id), vim.log.levels.ERROR)
    return false
  end
  plan.provider_sessions = plan.provider_sessions or {}
  if provider and provider ~= "" then
    if plan.provider_sessions[provider] then
      plan.provider_sessions[provider] = nil
      persist_plan(plan)
      vim.notify("nvime plan: " .. plan.id .. " — fresh session for next " .. provider .. " run", vim.log.levels.INFO)
    else
      vim.notify("nvime plan: no " .. provider .. " session captured for this plan", vim.log.levels.INFO)
    end
  else
    plan.provider_sessions = {}
    persist_plan(plan)
    vim.notify("nvime plan: " .. plan.id .. " — all sessions reset", vim.log.levels.INFO)
  end
  audit.write({
    event = "plan_session_reset",
    plan_id = plan.id,
    provider = provider,
  })
  return true
end

-- "Edit before exec" mode: open a scratch buffer with the would-be intent
-- + plan-context block prefilled. On <C-s>, the user's (possibly edited)
-- intent is fed to M.execute_step via the intent_override opt. On q the
-- compose is cancelled and nothing fires.
local STEP_COMPOSE_NS = vim.api.nvim_create_namespace("nvime.plan.step_compose")

function M.compose_step(plan_id, step_id, opts)
  opts = opts or {}
  local plan = M.get(plan_id)
  if not plan then
    vim.notify("nvime: unknown plan " .. tostring(plan_id), vim.log.levels.ERROR)
    return false
  end
  local step = find_step(plan, step_id)
  if not step then
    vim.notify("nvime: unknown step " .. tostring(step_id), vim.log.levels.ERROR)
    return false
  end

  -- Build the SAME intent string execute_step would fire — including the
  -- plan-context block — so the user can read & tweak the EXACT text the
  -- agent will see.
  local cfg = plan_config()
  local context = plan_context_block(plan, step, tonumber(cfg.inject_context_chars) or 480)
  local prefilled = (step.intent or "") .. "\n\n" .. context

  local buffer_name = "nvime://plan/step-compose/" .. plan_id .. "/" .. tostring(step_id)
  local bufnr = find_buffer(buffer_name)
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, buffer_name)
  end
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false

  -- Seed with a header so the user knows what each section is.
  local seed = {
    "# Step " .. tostring(step.id) .. "/" .. tostring(#(plan.steps or {})) .. " — " .. plan.id,
    "# File: " .. (step.file or "?") .. "  Range: " .. range_label(step),
    "# <C-s> fire   q close (cancel)   gC reset to original",
    "",
    "# === INTENT (the agent reads everything below this line) ===",
    "",
  }
  for _, line in ipairs(vim.split(prefilled, "\n", { plain = true })) do
    seed[#seed + 1] = line
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, seed)

  -- Decoration: dim the header lines so they stand out as instructions, not
  -- content the agent will see.
  vim.api.nvim_buf_clear_namespace(bufnr, STEP_COMPOSE_NS, 0, -1)
  ui.ensure_highlights()
  for row, line in ipairs(seed) do
    if line:sub(1, 1) == "#" then
      vim.api.nvim_buf_set_extmark(bufnr, STEP_COMPOSE_NS, row - 1, 0, {
        end_col = #line,
        hl_group = "NvimePlanWhy",
      })
    end
  end

  close_all_backdrops_except("compose")
  open_backdrop("compose")

  local cfg_ui = (state.config or {}).ui or {}
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = math.max(72, math.min(math.floor(columns * 0.74), columns - 4))
  local height = math.max(16, math.min(math.floor(lines * 0.62), lines - 4))
  local config = {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2 - 1)),
    col = math.max(0, math.floor((columns - width) / 2)),
    style = "minimal",
    border = cfg_ui.border or "rounded",
    title = " nvime plan · compose-then-fire step " .. tostring(step.id) .. " ",
    title_pos = "center",
    footer = " <C-s> fire · q cancel · gC reset ",
    footer_pos = "center",
    zindex = 54,
    focusable = true,
  }

  local existing = state.panels.plan_step_compose
  local winid
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_win_set_buf(existing.winid, bufnr)
    vim.api.nvim_win_set_config(existing.winid, config)
    configure_window(existing.winid)
    winid = existing.winid
  else
    winid = vim.api.nvim_open_win(bufnr, true, config)
    configure_window(winid)
  end
  state.panels.plan_step_compose = { bufnr = bufnr, winid = winid }
  pcall(vim.api.nvim_set_current_win, winid)
  -- Position cursor on the first content line under the INTENT header.
  pcall(vim.api.nvim_win_set_cursor, winid, { 7, 0 })

  -- Buffer-local keymaps
  for _, lhs in ipairs({ "<C-s>", "q", "<Esc>", "gC" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
  pcall(vim.keymap.del, "i", "<C-s>", { buffer = bufnr })
  local kopts = { buffer = bufnr, silent = true, nowait = true }

  local function close_step_compose()
    local panel = state.panels.plan_step_compose
    if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
      pcall(vim.api.nvim_win_close, panel.winid, true)
    end
    state.panels.plan_step_compose = nil
    close_backdrop("compose")
  end

  local function fire()
    -- Strip the leading header lines (`#` prefix at the START of the buffer
    -- only — once we hit a non-header line, everything after is content).
    local raw = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local first_content = 1
    for index, line in ipairs(raw) do
      if line:sub(1, 1) ~= "#" and line ~= "" then
        first_content = index
        break
      elseif line:sub(1, 1) ~= "#" then
        first_content = index + 1
      end
    end
    local body = {}
    for i = first_content, #raw do
      body[#body + 1] = raw[i]
    end
    local intent = vim.trim(table.concat(body, "\n"))
    if intent == "" then
      vim.notify("nvime: step compose is empty", vim.log.levels.WARN)
      return
    end
    close_step_compose()
    M.execute_step(plan_id, step_id, vim.tbl_extend("force", opts, { intent_override = intent }))
  end

  vim.keymap.set({ "n", "i", "v" }, "<C-s>", function()
    if vim.fn.mode() ~= "n" then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    end
    fire()
  end, vim.tbl_extend("force", kopts, { desc = "nvime plan: fire step with edited intent" }))

  vim.keymap.set(
    "n",
    "q",
    close_step_compose,
    vim.tbl_extend("force", kopts, { desc = "nvime plan: cancel step compose" })
  )
  vim.keymap.set(
    "n",
    "<Esc>",
    close_step_compose,
    vim.tbl_extend("force", kopts, { desc = "nvime plan: cancel step compose" })
  )
  vim.keymap.set("n", "gC", function()
    M.compose_step(plan_id, step_id, opts) -- reseed the buffer
  end, vim.tbl_extend("force", kopts, { desc = "nvime plan: reset compose to original intent" }))

  return true
end

function M.execute_step(plan_id, step_id, opts)
  opts = opts or {}
  local plan = M.get(plan_id)
  if not plan then
    vim.notify("nvime: unknown plan " .. tostring(plan_id), vim.log.levels.ERROR)
    return false
  end
  local step = find_step(plan, step_id)
  if not step then
    vim.notify("nvime: unknown step " .. tostring(step_id), vim.log.levels.ERROR)
    return false
  end

  if step.depends_on and #step.depends_on > 0 then
    local missing = {}
    for _, dep_id in ipairs(step.depends_on) do
      local dep = find_step(plan, dep_id)
      if not dep or step_status(dep) ~= "done" then
        missing[#missing + 1] = tostring(dep_id)
      end
    end
    if #missing > 0 and not opts.force then
      local choice = vim.fn.confirm(
        string.format(
          "Step %s depends on incomplete steps: %s. Run anyway?",
          tostring(step.id),
          table.concat(missing, ", ")
        ),
        "&Run\n&Cancel",
        2
      )
      if choice ~= 1 then
        return false
      end
    end
  end

  close_plan_view()

  local ok, selection = open_step_target(plan, step)
  if not ok then
    vim.notify("nvime: " .. tostring(selection), vim.log.levels.ERROR)
    return false
  end

  -- Confidence gate: when the target could not be located confidently (anchor
  -- ambiguous, or lost to drift and clamped to the stale recorded range), stop
  -- and let the user decide instead of silently editing the wrong lines and
  -- failing later. Skipped in headless / non-interactive runs, which proceed
  -- with the best guess (preserving prior behavior).
  local interactive = #vim.api.nvim_list_uis() > 0 and vim.env.NVIME_NONINTERACTIVE ~= "1"
  local confidence = selection.anchor_confidence
  if interactive and not opts.assume_yes and (confidence == "ambiguous" or confidence == "stale") then
    local choice = vim.fn.confirm(
      string.format(
        "nvime plan: step %s target is uncertain — %s.\nProceed with the best guess (lines %d-%d), edit the range, or cancel?",
        tostring(step.id),
        selection.anchor_notice or ("low confidence (" .. tostring(confidence) .. ")"),
        selection.line1,
        selection.line2
      ),
      "&Proceed\n&Edit range\n&Cancel",
      1
    )
    if choice == 2 then
      local default = string.format("%d,%d", selection.line1, selection.line2)
      local raw = vim.fn.input("nvime plan: line range for step " .. tostring(step.id) .. " (line1,line2): ", default)
      local a, b = tostring(raw):match("^%s*(%d+)%s*[,%s]%s*(%d+)%s*$")
      if a and b then
        selection.line1 = clamp_int(a, 1)
        selection.line2 = math.max(selection.line1, clamp_int(b, selection.line1))
        pcall(vim.api.nvim_win_set_cursor, 0, { selection.line1, 0 })
      end
    elseif choice ~= 1 then
      vim.notify("nvime plan: step " .. tostring(step.id) .. " cancelled (uncertain target)", vim.log.levels.WARN)
      return false
    end
  end

  local cfg = plan_config()
  if cfg.auto_in_progress ~= false then
    set_step_status(plan_id, step.id, "in_progress")
  end

  local context = plan_context_block(plan, step, tonumber(cfg.inject_context_chars) or 480)
  -- Honor the edit-before-exec opt-in path. compose_step prefills the
  -- generated intent + context, lets the user tweak, then calls
  -- execute_step with intent_override = the edited buffer body. We trust
  -- the user fully here: if they cleared the plan-context block, they
  -- meant to. Fall back to auto-generated intent + context otherwise.
  local intent
  if opts.intent_override and opts.intent_override ~= "" then
    intent = opts.intent_override
  else
    intent = (step.intent or "") .. "\n\n" .. context
  end

  audit.write({
    event = "plan_step_executing",
    plan_id = plan.id,
    step_id = step.id,
    file = step.file,
  })

  -- Restore the file to its pre-step content using the snapshot the diff
  -- session captured at start. Used by the test-failure rollback option so
  -- the user can recover with one keystroke instead of git-reverting by
  -- hand. We also save the file so the on-disk state matches the buffer.
  local function rollback_step(summary)
    local target_bufnr = summary and summary.target_bufnr
    local original_lines = summary and summary.original_lines
    if not target_bufnr or not vim.api.nvim_buf_is_valid(target_bufnr) or not original_lines then
      vim.notify("nvime plan: cannot rollback — original snapshot unavailable", vim.log.levels.ERROR)
      return false
    end
    local post_lines = vim.api.nvim_buf_get_lines(target_bufnr, 0, -1, false)
    vim.api.nvim_buf_set_lines(target_bufnr, 0, -1, false, original_lines)
    -- :write the buffer if it has a real file; suppress autocmds so other
    -- plugins don't reformat the rolled-back content.
    pcall(function()
      vim.api.nvim_buf_call(target_bufnr, function()
        vim.cmd("noautocmd silent! write")
      end)
    end)
    audit.write({
      event = "plan_step_rollback",
      plan_id = plan.id,
      step_id = step.id,
      file = summary.path,
    })
    vim.notify("nvime plan: step " .. tostring(step.id) .. " rolled back to pre-step content", vim.log.levels.WARN)
    -- Undo the live range-rebase applied when this step was accepted: the file
    -- is back to its pre-step content, so pending ranges must shift back too.
    rebase_pending_ranges(M.get(plan.id) or plan, summary.path or step.file, post_lines, original_lines, step.id)
    return true
  end

  -- When the user finishes reviewing the diff (every block accepted or
  -- rejected), auto-run the step's tests and offer to mark the step done.
  -- The user stays in control — we never auto-flip status without confirm.
  local on_resolved = function(summary)
    if (summary.accepted or 0) == 0 then
      vim.schedule(function()
        local choice = vim.fn.confirm(
          "nvime plan: step " .. tostring(step.id) .. " — every block was rejected. Mark this step blocked?",
          "&Blocked\n&Pending\n&Cancel",
          1
        )
        if choice == 1 then
          set_step_status(plan.id, step.id, "blocked")
        elseif choice == 2 then
          set_step_status(plan.id, step.id, "pending")
        end
      end)
      return
    end
    -- The file just changed under us (accepted > 0). Rebase the recorded line
    -- ranges of the remaining not-yet-done steps in this same file so they
    -- stay anchored as we walk the plan, instead of drifting and failing later.
    if summary.target_bufnr and vim.api.nvim_buf_is_valid(summary.target_bufnr) and summary.original_lines then
      local post_lines = vim.api.nvim_buf_get_lines(summary.target_bufnr, 0, -1, false)
      rebase_pending_ranges(M.get(plan.id) or plan, step.file, summary.original_lines, post_lines, step.id)
    end
    local tests = step.tests or {}
    -- Count force-accepts in this resolution so the changelog flags them.
    local forced_count = 0
    for _, entry in ipairs(summary.applied_history or {}) do
      if entry.block and entry.block.was_forced then
        forced_count = forced_count + 1
      end
    end
    if #tests == 0 then
      vim.schedule(function()
        local choice = vim.fn.confirm(
          "nvime plan: step "
            .. tostring(step.id)
            .. " accepted ("
            .. summary.accepted
            .. "/"
            .. summary.total
            .. " blocks). No tests defined. Mark done?",
          "&Done\n&Pending\n&Cancel",
          1
        )
        if choice == 1 then
          set_step_status(plan.id, step.id, "done", {
            provider = summary.provider,
            rationale = summary.rationale,
            verdict = summary.verdict,
            verdict_pending = summary.verdict == nil,
            accepted = summary.accepted,
            total = summary.total,
            forced = forced_count,
          })
        elseif choice == 2 then
          set_step_status(plan.id, step.id, "pending")
        end
      end)
      return
    end
    vim.schedule(function()
      -- Save the target buffer to disk before running tests. The diff
      -- acceptance path writes to the BUFFER, not the file; tools that read
      -- from disk (stylua --check, ./scripts/test, rg/grep, etc.) would
      -- otherwise see stale content and report a false failure.
      local target_bufnr = summary and summary.target_bufnr
      if target_bufnr and vim.api.nvim_buf_is_valid(target_bufnr) and vim.bo[target_bufnr].modified then
        pcall(function()
          vim.api.nvim_buf_call(target_bufnr, function()
            vim.cmd("noautocmd silent! write")
          end)
        end)
      end
      vim.notify("nvime plan: running step " .. tostring(step.id) .. " tests…", vim.log.levels.INFO)
      local cmd = table.concat(tests, " && ")
      local cwd = git.root() or vim.fn.getcwd()
      vim.system({ "sh", "-lc", cmd }, { cwd = cwd, text = true }, function(result)
        vim.schedule(function()
          local stdout = (result.stdout or ""):gsub("%s+$", "")
          local stderr = (result.stderr or ""):gsub("%s+$", "")
          local tail = stdout
          if stderr ~= "" then
            tail = (tail ~= "" and (tail .. "\n") or "") .. stderr
          end
          if #tail > 1200 then
            tail = tail:sub(-1200)
          end
          if result.code == 0 then
            local choice = vim.fn.confirm(
              "nvime plan: step "
                .. tostring(step.id)
                .. " tests PASSED. Mark step done?\n\nLast output:\n"
                .. (tail ~= "" and tail or "(no output)"),
              "&Done\n&Pending\n&Cancel",
              1
            )
            if choice == 1 then
              set_step_status(plan.id, step.id, "done", {
                provider = summary.provider,
                rationale = summary.rationale,
                verdict = summary.verdict,
                verdict_pending = summary.verdict == nil,
                accepted = summary.accepted,
                total = summary.total,
                forced = forced_count,
                tests_cmd = cmd,
                tests_pass = true,
                tests_tail = tail,
              })
            elseif choice == 2 then
              set_step_status(plan.id, step.id, "pending")
            end
          else
            -- Surface the acceptance criteria with a per-check ✓/✗ so the user
            -- sees WHAT was required and WHY it failed — not a bare "exit 1".
            -- A single compound check is already known-failed (don't re-run a
            -- possibly-slow suite); multiple checks get re-run individually to
            -- pinpoint the culprit.
            local criteria = {}
            if #tests == 1 then
              criteria[1] = "  ✗ " .. tests[1]
            else
              for _, t in ipairs(tests) do
                local r = vim.system({ "sh", "-lc", t }, { cwd = cwd, text = true }):wait()
                criteria[#criteria + 1] = (r.code == 0 and "  ✓ " or "  ✗ ") .. t
              end
            end
            local why = tail ~= "" and tail or "(silent checks — e.g. grep -q — produced no output)"
            local criteria_text = table.concat(criteria, "\n")

            local choice = vim.fn.confirm(
              "nvime plan: step "
                .. tostring(step.id)
                .. " checks FAILED (exit "
                .. tostring(result.code)
                .. ").\n\nAcceptance criteria:\n"
                .. criteria_text
                .. "\n\nWhy:\n"
                .. why
                .. "\n\nFix this?",
              "&Fix with agent\n&Ignore (mark done)\n&Revert\n&Cancel",
              4
            )
            if choice == 1 then
              -- Hand the failure back to the patch agent on this step's range.
              local fix_intent = table.concat({
                "Plan step " .. tostring(step.id) .. "'s change was applied but its acceptance checks FAILED. Fix it.",
                "",
                "Acceptance checks (shell; each must exit 0):",
                criteria_text,
                "",
                "Exit code: " .. tostring(result.code),
                "Captured output:",
                why,
                "",
                "Adjust the code in this step's range so every acceptance check passes."
                  .. " Keep the change minimal and focused; do not touch unrelated lines.",
              }, "\n")
              vim.notify(
                "nvime plan: handing step " .. tostring(step.id) .. " back to the agent to fix…",
                vim.log.levels.INFO
              )
              M.execute_step(plan.id, step.id, { intent_override = fix_intent, force = true })
            elseif choice == 2 then
              -- Ignore: the user judges the check wrong/irrelevant. Keep the work
              -- and mark done, but record that the checks failed (changelog flags it).
              set_step_status(plan.id, step.id, "done", {
                provider = summary.provider,
                rationale = summary.rationale,
                verdict = summary.verdict,
                verdict_pending = summary.verdict == nil,
                accepted = summary.accepted,
                total = summary.total,
                forced = forced_count,
                tests_cmd = cmd,
                tests_pass = false,
                tests_tail = tail,
              })
              vim.notify(
                "nvime plan: step " .. tostring(step.id) .. " marked done despite failing checks (ignored)",
                vim.log.levels.WARN
              )
            elseif choice == 3 then
              if rollback_step(summary) then
                set_step_status(plan.id, step.id, "pending")
              else
                set_step_status(plan.id, step.id, "blocked")
              end
            end
            -- choice 4 (Cancel) / 0: leave the step as-is; the user decides later
            -- from the plan view.
          end
        end)
      end)
    end)
  end

  -- Plan-execution prefers the critic on by default (overrides the
  -- diff.devils_advocate global) because plan steps are structured and the
  -- second-pass review materially raises bar. Caller can override.
  local devils_advocate = opts.devils_advocate
  if devils_advocate == nil then
    local plan_cfg = (state.config or {}).plan or {}
    devils_advocate = plan_cfg.devils_advocate ~= false
  end

  -- Plan-level session continuity: reuse the provider session captured
  -- during plan_author so every step picks up where the previous one left
  -- off. The on_session_id callback rotates the stored id whenever the
  -- agent emits a new one (claude/codex assign new ids on every --resume).
  local provider_for_continuity = opts.provider or (state.config and state.config.provider) or "claude"
  local plan_continuity = nil
  local plan_cfg = (state.config or {}).plan or {}
  local continuity_mode = opts.continuity or plan_cfg.session_continuity or "plan"
  if continuity_mode == "plan" then
    local resume_id = plan.provider_sessions and plan.provider_sessions[provider_for_continuity] or nil
    plan_continuity = {
      resume_session_id = resume_id,
      on_session_id = function(new_id)
        if not new_id or new_id == "" then
          return
        end
        -- on_session_id fires from agents.run's stdout libuv callback (a
        -- "fast event context"). vim.fn.mkdir / vim.fn.writefile inside
        -- persist_plan are forbidden there; defer to the main loop.
        vim.schedule(function()
          local fresh = M.get(plan.id)
          if not fresh then
            return
          end
          fresh.provider_sessions = fresh.provider_sessions or {}
          if fresh.provider_sessions[provider_for_continuity] ~= new_id then
            fresh.provider_sessions[provider_for_continuity] = new_id
            persist_plan(fresh)
          end
        end)
      end,
    }
  end

  -- on_run_failed: edit lane invokes this when the agent run exits non-zero
  -- (e.g. claude rejected our --resume id with "No conversation found").
  -- We clear the bad id so the next attempt starts fresh instead of looping
  -- forever on the same broken resume.
  local on_run_failed = function(info)
    if info and info.stale_resume then
      vim.schedule(function()
        local fresh = M.get(plan.id)
        if fresh and fresh.provider_sessions then
          fresh.provider_sessions[provider_for_continuity] = nil
          persist_plan(fresh)
        end
        vim.notify(
          "nvime plan: provider rejected the stored session id (resume failed). "
            .. "Cleared the captured id; press <CR> on the step to retry with a fresh session.",
          vim.log.levels.WARN
        )
      end)
    end
  end

  require("nvime.edit").start({
    selection = selection,
    prefill = intent,
    line1 = selection.line1,
    line2 = selection.line2,
    range = 2,
    provider = opts.provider,
    force_edit = true,
    on_resolved = on_resolved,
    on_run_failed = on_run_failed,
    devils_advocate = devils_advocate,
    plan_continuity = plan_continuity,
    plan_id = plan.id,
    plan_step_id = step.id,
  })
  return true
end

-- ============================================================================
-- Plan view keymaps
-- ============================================================================

install_plan_view_keymaps = function(bufnr, plan_id, step_index)
  -- Defensive: clear any stale buffer-local maps so reusing the buffer across
  -- opens doesn't leave dead closures, and so the global `gx` (vim.ui.open
  -- in nvim 0.10+) can't sneak through if a previous install_*  removed and
  -- failed to re-set our binding.
  for _, lhs in ipairs({
    "<CR>",
    "gx",
    "gp",
    "gB",
    "gT",
    "]s",
    "[s",
    "gA",
    "o",
    "c",
    "gd",
    "gr",
    "gW",
    "gN",
    "gE",
    "q",
    "<Esc>",
    "?",
  }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
  local opts = { buffer = bufnr, silent = true, nowait = true }

  local function step_or_warn()
    local id = step_at_cursor(step_index)
    if not id then
      vim.notify("nvime: place cursor on a step", vim.log.levels.WARN)
    end
    return id
  end

  vim.keymap.set("n", "<CR>", function()
    local id = step_or_warn()
    if id then
      M.execute_step(plan_id, id)
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: execute step" }))

  vim.keymap.set("n", "gx", function()
    local id = step_or_warn()
    if id then
      set_step_status(plan_id, id, "done")
      M.open(plan_id)
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: mark step done" }))

  vim.keymap.set("n", "gp", function()
    local id = step_or_warn()
    if id then
      set_step_status(plan_id, id, "pending")
      M.open(plan_id)
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: mark step pending" }))

  vim.keymap.set("n", "gB", function()
    local id = step_or_warn()
    if id then
      set_step_status(plan_id, id, "blocked")
      M.open(plan_id)
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: mark step blocked" }))

  vim.keymap.set("n", "gT", function()
    local id = step_or_warn()
    if not id then
      return
    end
    local plan = M.get(plan_id)
    local step = plan and find_step(plan, id)
    if not step or not step.tests or #step.tests == 0 then
      vim.notify("nvime: step has no tests", vim.log.levels.INFO)
      return
    end
    local cmd = table.concat(step.tests, " && ")
    vim.notify("nvime: running tests — " .. cmd, vim.log.levels.INFO)
    vim.cmd("botright split | resize 12 | terminal " .. vim.fn.shellescape("sh -lc '" .. cmd:gsub("'", "'\\''") .. "'"))
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: run step tests" }))

  vim.keymap.set("n", "gW", function()
    -- "g write-test" — fire the test scaffolder for the step under cursor.
    -- Lands in tests/headless_spec.lua (or your configured plan.test_file)
    -- through the existing edit lane diff review.
    local id = step_or_warn()
    if id then
      M.add_test_for_step(plan_id, id)
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: scaffold a regression test" }))

  vim.keymap.set("n", "gN", function()
    -- "g new-session" — clear the plan's captured provider session so the
    -- next step / refinement starts fresh. Useful when the conversation has
    -- gotten too long or off-track. Affects the current default provider;
    -- pass a provider arg via :NvimePlan reset-session <id> [provider] for
    -- finer control.
    local plan = M.get(plan_id)
    if not plan then
      return
    end
    local provider_name = (state.config and state.config.provider) or "claude"
    M.reset_session(plan_id, provider_name)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: reset provider session (next step starts fresh)" }))

  vim.keymap.set("n", "gE", function()
    -- "g edit-then-execute" — open a compose buffer with the would-be intent
    -- + plan context prefilled. The user can tweak (correct line numbers,
    -- add hints, narrow the request) before <C-s> actually fires the
    -- patch worker.
    local id = step_or_warn()
    if id then
      M.compose_step(plan_id, id)
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: edit intent before firing" }))

  vim.keymap.set("n", "]s", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local sorted = {}
    for id, range in pairs(step_index) do
      sorted[#sorted + 1] = { id = id, first = range.first + 1 }
    end
    table.sort(sorted, function(a, b)
      return a.first < b.first
    end)
    for _, entry in ipairs(sorted) do
      if entry.first > row then
        vim.api.nvim_win_set_cursor(0, { entry.first, 0 })
        return
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: next step" }))

  vim.keymap.set("n", "[s", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local sorted = {}
    for id, range in pairs(step_index) do
      sorted[#sorted + 1] = { id = id, first = range.first + 1 }
    end
    table.sort(sorted, function(a, b)
      return a.first > b.first
    end)
    for _, entry in ipairs(sorted) do
      if entry.first < row then
        vim.api.nvim_win_set_cursor(0, { entry.first, 0 })
        return
      end
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: previous step" }))

  vim.keymap.set("n", "gA", function()
    local plan = M.get(plan_id)
    if not plan then
      return
    end
    local pending = {}
    for _, step in ipairs(plan.steps or {}) do
      if step_status(step) == "pending" then
        pending[#pending + 1] = step.id
      end
    end
    if #pending == 0 then
      vim.notify("nvime: no pending steps to run", vim.log.levels.INFO)
      return
    end
    M.execute_step(plan_id, pending[1])
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: run next pending" }))

  vim.keymap.set("n", "o", function()
    local id = step_or_warn()
    if not id then
      return
    end
    local plan = M.get(plan_id)
    local step = plan and find_step(plan, id)
    if not step then
      return
    end
    close_plan_view()
    open_step_target(plan, step)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: open file" }))

  vim.keymap.set("n", "c", function()
    local id = step_or_warn()
    if not id then
      return
    end
    local plan = M.get(plan_id)
    local step = plan and find_step(plan, id)
    if not step then
      return
    end
    vim.fn.setreg("+", step.intent or "")
    vim.fn.setreg('"', step.intent or "")
    vim.notify("nvime: copied step intent", vim.log.levels.INFO)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: copy intent" }))

  vim.keymap.set("n", "gd", function()
    local id = step_at_cursor(step_index)
    M.discuss(plan_id, id)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: discuss/refine" }))

  vim.keymap.set("n", "gr", function()
    M.replan(plan_id)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: replan" }))

  vim.keymap.set("n", "q", close_plan_view, vim.tbl_extend("force", opts, { desc = "nvime plan: close" }))
  vim.keymap.set("n", "<Esc>", close_plan_view, vim.tbl_extend("force", opts, { desc = "nvime plan: close" }))
  vim.keymap.set("n", "?", function()
    vim.notify(
      table.concat({
        "nvime plan keys:",
        "<CR> execute step    gx mark done       gp mark pending     gB mark blocked",
        "gT run step tests   ]s/[s next/prev    gA run next pending  gd refine/discuss",
        "gr replan          o open file        c copy intent       q close",
      }, "\n"),
      vim.log.levels.INFO
    )
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: help" }))
end

function M.open(plan_id)
  M.refresh()
  local plan = M.get(plan_id)
  if not plan then
    vim.notify("nvime: unknown plan " .. tostring(plan_id), vim.log.levels.ERROR)
    return
  end
  local bufnr, _, step_index = render_plan(plan, { open = true })
  install_plan_view_keymaps(bufnr, plan.id, step_index)
end

-- ============================================================================
-- Plan author runner
-- ============================================================================

local AUTHOR_PROMPT_HEADER = table.concat({
  "NVIME PLAN AUTHOR MODE.",
  "",
  "You are an architect drafting a structured implementation plan for a code change in this repository.",
  "Do not narrate tool use, investigation progress, or status updates. Your final stdout must start with NVIME_PLAN.",
  "",
  "You MUST NOT modify any source code under the repository root EXCEPT under `.nvime/plans/<plan-id>/`.",
  "nvime synchronizes ONLY files under `.nvime/plans/` back to the user's repository when you exit; anything else you write is silently dropped.",
  "",
  "Tools: Read/Grep/LS/Glob to study the codebase; Bash to run tests, lints, ./scripts/test, git log and ground claims in real evidence; web fetch/search for external context; Write/Edit ONLY for paths under `.nvime/plans/<plan-id>/`.",
  "",
  "Workflow:",
  "  1. Read the user's intent.",
  "  2. Investigate the repo. Be specific: identify actual files, line numbers, dependencies. If nvime MCP tools are available, call nvime.check_policy on each file you plan to touch and RESPECT + CITE the returned constraints (human-only paths, max changed-lines budgets, allowed lanes) in the step notes — they are constraints to honor, not permission to proceed.",
  "  3. Decompose into ORDERED steps. Each step:",
  '     - Targets exactly ONE file and ONE range (existing range, or "new" for a new file).',
  "     - Is small enough to apply through a focused diff review (~5-100 lines).",
  "     - Has CHECKABLE acceptance criteria — prefer shell commands and observable behavior.",
  "     - Match the NUMBER of steps to the ACTUAL scope. Most requests are small: a localized, single-file change is ONE step. Only add steps when the work genuinely spans multiple files, ranges, or independently-reviewable units. NEVER pad a small change with artificial steps or split one coherent edit just to raise the step count.",
  "  4. Write `.nvime/plans/<plan-id>/plan.json` with the schema below.",
  "  5. Write `.nvime/plans/<plan-id>/plan.md` — a human-readable narrative a future engineer can read cold.",
  "  6. Emit ONE machine-readable marker as the FINAL output (no other prose):",
  "",
  "NVIME_PLAN",
  "```json",
  '{ "id": "<plan-id>", "summary": "<one-sentence what+why>", "step_count": <N>, "files_estimated": ["..."] }',
  "```",
  "",
  "Plan id format: `NNNN-<kebab-slug>`. Pick the next free 4-digit number by listing `.nvime/plans/`.",
  "",
  "plan.json schema (version 1):",
  "{",
  '  "version": 1,',
  '  "id": "NNNN-slug",',
  '  "title": "...",',
  '  "why": "...",',
  '  "created_at": <unix timestamp>,',
  '  "files_estimated": ["path1", "path2"],',
  '  "acceptance": [ { "id": 1, "text": "...", "status": "pending" } ],',
  '  "steps": [',
  "    {",
  '      "id": 1,',
  '      "intent": "Concrete instruction to a future patch worker. Include WHAT, not WHY.",',
  '      "file": "path/relative/to/repo",',
  '      "range": { "line1": 12, "line2": 45 },   // or "new"',
  '      "range_anchor": "first verbatim line of original content at line 12",',
  '      "depends_on": [],',
  '      "tests": ["<project-native test runner>"],',
  '      "status": "pending",',
  '      "notes": "optional context"',
  "    }",
  "  ]",
  "}",
  "",
  "Quality bar:",
  "  - Read enough of the actual code to ground every line/range you cite.",
  "  - If the work has uncertainty, encode the choice in `notes`. Don't punt.",
  "  - For runtime behavior changes, ensure a regression test exists — for a small change put it in the implementation step's `tests` field rather than a separate test step; add a dedicated test step only when the test work is substantial enough to review on its own.",
  "  - If the codebase already has a tracked roadmap (e.g. IMPROVEMENTS.md), cite the relevant section in `why`.",
  "",
  "Tests are load-bearing:",
  "  Every step that changes runtime behavior MUST have ONE of the following:",
  "    (a) a `tests` field whose entries are real shell commands that exercise the new behavior (NOT just the project test runner unless the existing tests cover the new behavior); OR",
  "    (b) an explicit follow-up step in the plan that adds a regression test, with `depends_on` pointing back at the behavior step.",
  '  Pure cosmetic / formatting / dead-code-removal steps are exempt: mark them with `notes: "no behavior change; lint-only"`.',
  "  When in doubt, pick (b) — a separate test step is small, reviewable, and catches the case where the implementation drifts.",
  "",
  "Step coherence (tests vs implementation):",
  "  When a plan splits a single behavior into separate implementation step(s) and test step(s):",
  "    - Pin the API contract in BOTH steps. The implementation step's `intent` AND the test step's `intent` must literally restate: exact public function names, parameter signatures (including which arguments are positional vs keyword vs nested-in-a-dict), attribute/method names, return shapes, and numeric bounds (timeouts, jitter percentages, retry counts, window sizes, exponent bases).",
  "    - The test step MUST assert against THAT exact contract — same function names, same call shape, same numeric bounds. Do not invent new keyword arguments. Do not assume tighter bounds than the implementation guarantees. Do not assert against helper attributes that aren't part of the contract.",
  "    - If the user's intent already pins a contract (e.g. 'enqueue takes a single dict argument'), copy that wording verbatim into BOTH the implementation step's intent AND the test step's intent. Do not paraphrase signatures.",
  "    - When asserting on numeric backoff/jitter bounds, write the bound formula in the test step's intent — e.g. 'assert next_attempt_at - now is in [delay, delay * 1.25] where delay = base_delay * (2 ** attempt)'. The test code must compute the same `delay` formula the implementation uses.",
  "    - If the test step needs a different bound than the implementation provides, that is a SPEC change: update the implementation step's intent first so reviewers see them in the same plan, then write the test against the updated contract.",
  "  This rule exists because plan-execute runs each step as an independent edit-lane call — a test step that asserts a contract the implementation step did not promise will pass the patch-worker's local check but fail at the project test runner.",
  "",
  "  Use the project's NATIVE test runner. Detect it from markers in the repo root:",
  "    Cargo.toml      → `cargo test --quiet`",
  "    build.zig       → `zig build test`",
  "    go.mod          → `go test ./...`",
  "    pyproject.toml / pytest.ini / setup.py → `pytest -q`",
  "    package.json    → `npm test --silent`",
  "    pom.xml         → `mvn -q test`",
  "    build.gradle    → `gradle -q test`",
  "    CMakeLists.txt  → `ctest --output-on-failure`",
  "    Makefile        → `make test`",
  "    scripts/test    → `./scripts/test`",
  "  Linters/formatters are language-specific too: pick what the project actually uses",
  "  (`stylua --check`, `rustfmt --check`, `gofmt -d`, `black --check`, `prettier --check`,",
  "  `clang-format --dry-run -Werror`, `zig fmt --check`, `ktlint`, etc.).",
  "  Example bad entries:",
  '    "manually verify in <editor>"   (not automatable)',
  '    "add tests later"               (not a check)',
  "",
  "Plan acceptance bar:",
  "  The top-level `acceptance` array must include AT LEAST one item per acceptance category that applies:",
  "    - functional: the behavior the user asked for is observable",
  "    - regression: a green run of the project test runner AFTER the last step",
  "    - lint: the project's formatter / linter is clean on the touched files",
  "  Each acceptance entry should be a checkable shell command or an observable behavior, not vague phrases.",
  "",
  "Range anchors (resilience to file drift): when earlier steps shift line numbers, a later step's range can drift out of place.",
  '  For every step whose `range` is a line block (NOT "new"), add a `range_anchor`: the FIRST 1-3 lines of the original content at that range, verbatim with leading whitespace. nvime re-anchors the range to wherever that content moved; without it, drift makes the patch worker refuse the step.',
  "  Pick a UNIQUE anchor (a signature or declaration, not `end`, `}`, `return`, or a blank line); if the first line is not unique, include up to 3 following lines so the block appears exactly once.",
  "",
}, "\n")

local function build_author_prompt(intent, existing_id)
  local lines = { AUTHOR_PROMPT_HEADER }
  if existing_id and existing_id ~= "" then
    lines[#lines + 1] = "Refining existing plan: " .. existing_id
    lines[#lines + 1] = "Read `.nvime/plans/" .. existing_id .. "/plan.json` first and treat it as the baseline."
    lines[#lines + 1] = "Use the same plan id. Update the existing files in place."
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "User intent:"
  lines[#lines + 1] = intent or ""
  return table.concat(lines, "\n")
end

local function format_run_log()
  local panel = state.panels.plan_run
  if panel and panel.bufnr and vim.api.nvim_buf_is_valid(panel.bufnr) then
    return panel.bufnr
  end
  -- The run-log buffer is bufhidden="hide", so closing its window only hides it
  -- — the named buffer survives even though WinClosed drops the panel reference.
  -- Reuse the existing buffer by name (clearing it) rather than creating a fresh
  -- one and colliding on the name (E95) on a second author run this session.
  local bufnr = find_buffer("nvime://plan/run")
  if bufnr then
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})
  else
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, "nvime://plan/run")
  end
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "nvime"
  state.panels.plan_run = { bufnr = bufnr }
  return bufnr
end

local function open_run_window(bufnr)
  local existing = state.panels.plan_run
  local dim = dimensions()
  local config = {
    relative = "editor",
    width = dim.width,
    height = math.max(14, math.floor(dim.height * 0.7)),
    row = math.max(0, math.floor((vim.o.lines - math.max(14, math.floor(dim.height * 0.7))) / 2 - 1)),
    col = dim.col,
    style = "minimal",
    border = dim.border,
    title = " nvime plan author ",
    title_pos = "center",
    footer = " streaming · <C-c> cancel · q/<Esc> close (output preserved) ",
    footer_pos = "center",
    zindex = 54,
    focusable = true,
  }
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_win_set_buf(existing.winid, bufnr)
    vim.api.nvim_win_set_config(existing.winid, config)
    configure_window(existing.winid)
    return existing.winid
  end
  local winid = vim.api.nvim_open_win(bufnr, true, config)
  configure_window(winid)
  state.panels.plan_run = { bufnr = bufnr, winid = winid }
  return winid
end

local function close_run_window()
  local panel = state.panels.plan_run
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_close, panel.winid, true)
    panel.winid = nil
  end
  close_backdrop("run")
end

local function install_run_panel_keymaps(bufnr)
  for _, lhs in ipairs({ "q", "<Esc>", "<C-c>" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "q", close_run_window, vim.tbl_extend("force", opts, { desc = "nvime plan run: close" }))
  vim.keymap.set("n", "<Esc>", close_run_window, vim.tbl_extend("force", opts, { desc = "nvime plan run: close" }))
  vim.keymap.set("n", "<C-c>", function()
    local active = state.plan and state.plan.active_run
    if active and active.handle and active.handle.kill then
      pcall(active.handle.kill, active.handle, "sigterm")
      vim.notify("nvime: cancelled plan author run", vim.log.levels.INFO)
    else
      close_run_window()
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan run: cancel running" }))
end

local PLAN_RUN_NS = vim.api.nvim_create_namespace("nvime.plan.run.scrollback")

local function run_panel_append(text)
  -- agents.run's on_text / on_progress fire from libuv callbacks (a "fast
  -- event context"). nvim_buf_is_valid and nvim_buf_set_lines are NOT safe
  -- there; we must defer to the main loop via vim.schedule. Without this,
  -- streaming output crashes the plan author the instant the first chunk
  -- arrives.
  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(function()
      run_panel_append(text)
    end)
    return
  end
  local panel = state.panels.plan_run
  if not panel or not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
    return
  end
  local bufnr = panel.bufnr
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local last = current[#current] or ""
  local pieces = vim.split(text or "", "\n", { plain = true })
  vim.bo[bufnr].modifiable = true
  if #pieces == 1 then
    current[#current] = last .. pieces[1]
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, current)
  else
    current[#current] = last .. pieces[1]
    for i = 2, #pieces do
      current[#current + 1] = pieces[i]
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, current)
  end
  vim.bo[bufnr].modifiable = false
  -- Re-decorate the streaming panel with markdown-aware highlights so
  -- the plan author's prose (headings, code, lists, bold, links) is
  -- legible while it's still being written.
  local ok_render, render = pcall(require, "nvime.render")
  if ok_render and render and type(render.scrollback) == "function" then
    pcall(render.scrollback, bufnr, PLAN_RUN_NS)
  end
  if panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_set_cursor, panel.winid, { vim.api.nvim_buf_line_count(bufnr), 0 })
  end
end

local function parse_marker_payload(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  local idx = text:find("NVIME_PLAN", 1, true)
  if not idx then
    return nil
  end
  local tail = text:sub(idx + #"NVIME_PLAN")
  local body = tail:match("```json%s*(.-)```") or tail:match("```%s*(.-)```")
  if not body then
    -- Try to find a top-level json object on the next non-empty lines
    body = tail:match("(%b{})")
  end
  if not body then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, body)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

function M.create(opts)
  opts = opts or {}
  local intent = opts.intent
  if not intent or intent == "" then
    vim.notify("nvime: plan creation needs an intent", vim.log.levels.ERROR)
    return
  end
  ensure_dir(plans_dir())

  local provider = opts.provider or (state.config and state.config.provider) or "claude"
  local prompt = build_author_prompt(intent, opts.refine_id)
  local response = {}
  local run_bufnr = format_run_log()
  vim.bo[run_bufnr].modifiable = true
  local seed = {
    "  nvime plan author",
    "  provider: " .. provider .. (opts.refine_id and ("  · refining " .. opts.refine_id) or ""),
  }
  local intent_lines = vim.split(intent, "\n", { plain = true })
  seed[#seed + 1] = "  intent: " .. (intent_lines[1] or "")
  for i = 2, #intent_lines do
    seed[#seed + 1] = "          " .. intent_lines[i]
  end
  seed[#seed + 1] = string.rep("─", 78)
  seed[#seed + 1] = ""
  vim.api.nvim_buf_set_lines(run_bufnr, 0, -1, false, seed)
  vim.bo[run_bufnr].modifiable = false
  close_all_backdrops_except("run")
  open_backdrop("run")
  local run_winid = open_run_window(run_bufnr)
  install_run_panel_keymaps(run_bufnr)
  if run_winid then
    pcall(vim.api.nvim_set_current_win, run_winid)
  end

  -- Pull a short title from the intent (first non-empty line, capped) for
  -- display in the picker while the run is in flight.
  local title_excerpt = nil
  for _, line in ipairs(vim.split(intent or "", "\n", { plain = true })) do
    line = (line or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      title_excerpt = line:gsub("^Plan title:%s*", "")
      if #title_excerpt > 64 then
        title_excerpt = title_excerpt:sub(1, 61) .. "..."
      end
      break
    end
  end
  state.plan.active_run = {
    provider = provider,
    intent = intent,
    title = title_excerpt or "(plan author run)",
    started_at = now_ts(),
    bufnr = run_bufnr,
    refine_id = opts.refine_id,
    status = "drafting",
  }
  -- Live picker refresh: while the run is in flight, refresh the picker every
  -- 1.5s so the elapsed-time meta updates in place. The timer is cancelled
  -- when active_run is cleared.
  if state.plan._tick_timer then
    pcall(state.plan._tick_timer.stop, state.plan._tick_timer)
    pcall(state.plan._tick_timer.close, state.plan._tick_timer)
  end
  local timer = (vim.uv or vim.loop).new_timer()
  state.plan._tick_timer = timer
  timer:start(
    1500,
    1500,
    vim.schedule_wrap(function()
      if not state.plan.active_run or state.plan.active_run.finished_at then
        if state.plan._tick_timer == timer then
          pcall(timer.stop, timer)
          pcall(timer.close, timer)
          state.plan._tick_timer = nil
        end
        return
      end
      if
        state.panels.plan_picker
        and state.panels.plan_picker.winid
        and vim.api.nvim_win_is_valid(state.panels.plan_picker.winid)
      then
        refresh_picker()
      end
    end)
  )

  audit.write({ event = "plan_author_start", provider = provider, intent = intent })

  local handle
  -- Plan-level session continuity: when refining an existing plan, resume
  -- the captured provider session so the architect retains its prior
  -- investigation context. When drafting a new plan we still ask the agent
  -- to persist the session so subsequent refinements can resume.
  --
  -- IMPORTANT: plan_author runs in a temp workspace (prepare_plan_workspace);
  -- the session id Claude assigns is scoped to that cwd. plan_exec runs in
  -- the real repo root with a different cwd, so it cannot resume a session
  -- captured here. Author sessions therefore live in `author_provider_sessions`
  -- (used only by future plan_author refinements). plan_exec uses the
  -- separate `provider_sessions` table, which it owns and rotates itself.
  local resume_session_id = nil
  if opts.refine_id and opts.refine_id ~= "" then
    local existing_plan = M.get(opts.refine_id)
    if existing_plan and existing_plan.author_provider_sessions then
      resume_session_id = existing_plan.author_provider_sessions[provider]
    end
  end
  local captured_session_id = resume_session_id

  handle = agents.run({
    provider = provider,
    lane = "plan",
    prompt = prompt,
    persist_session = true,
    resume_session_id = resume_session_id,
    on_session_id = function(id)
      if id and id ~= "" then
        captured_session_id = id
      end
    end,
    on_text = function(text)
      response[#response + 1] = text
      run_panel_append(text)
    end,
    on_progress = function(text)
      run_panel_append(text)
    end,
    on_handle = function(h)
      handle = h
      if state.plan.active_run then
        state.plan.active_run.handle = h
      end
    end,
    on_exit = function(result)
      local synced = result.nvime_synced_plan_files or {}
      local body = table.concat(response)
      local marker = parse_marker_payload(body)
      audit.write({
        event = "plan_author_exit",
        code = result.code,
        provider = provider,
        synced_plan_files = synced,
        marker = marker,
      })
      run_panel_append("\n" .. string.rep("─", 78) .. "\n")

      local plan_id = nil
      local final_status = "ok"
      if result.code ~= 0 then
        final_status = "failed"
        run_panel_append("[nvime] plan author failed (code " .. tostring(result.code) .. ")\n")
      elseif #synced == 0 then
        final_status = "no_output"
        run_panel_append("[nvime] no plan files were written; the agent may have refused.\n")
      else
        if marker and marker.id then
          plan_id = marker.id
        else
          for _, rel in ipairs(synced) do
            local id = rel:match("^%.nvime/plans/([^/]+)/plan%.json$")
            if id then
              plan_id = id
              break
            end
          end
        end
        run_panel_append(
          string.format("[nvime] synced %d plan file(s)%s\n", #synced, plan_id and (" · plan " .. plan_id) or "")
        )
        M.refresh()
        -- Persist the captured author session under author_provider_sessions
        -- so future refinements (which also run in the temp workspace cwd)
        -- can resume. Do NOT write to provider_sessions — that is owned by
        -- plan_exec and lives in a different cwd, where this id won't work.
        if plan_id and captured_session_id then
          local fresh = M.get(plan_id)
          if fresh then
            fresh.author_provider_sessions = fresh.author_provider_sessions or {}
            fresh.author_provider_sessions[provider] = captured_session_id
            persist_plan(fresh)
          end
        end
        if plan_id and (plan_config().auto_open ~= false) then
          vim.defer_fn(function()
            close_run_window()
            M.open(plan_id)
          end, 250)
        end
      end

      -- Always update active_run state with terminal status, never leak it.
      if state.plan.active_run then
        state.plan.active_run.finished_at = now_ts()
        state.plan.active_run.status = final_status
        state.plan.active_run.plan_id = plan_id
      end
      -- Clear after a brief grace window so the picker can show "just finished"
      -- if the user opens it within the next few seconds.
      vim.defer_fn(function()
        if state.plan.active_run and state.plan.active_run.finished_at then
          state.plan.active_run = nil
          if
            state.panels.plan_picker
            and state.panels.plan_picker.winid
            and vim.api.nvim_win_is_valid(state.panels.plan_picker.winid)
          then
            refresh_picker()
          end
        end
      end, 8000)

      -- Refresh the picker right now if it's open so the user sees the
      -- terminal state immediately.
      if
        state.panels.plan_picker
        and state.panels.plan_picker.winid
        and vim.api.nvim_win_is_valid(state.panels.plan_picker.winid)
      then
        refresh_picker()
      end
    end,
  })
end

function M.refine(plan_id, intent)
  M.create({ intent = intent, refine_id = plan_id })
end

function M.replan(plan_id)
  M.compose({ refine_id = plan_id })
end

function M.discuss(plan_id, step_id)
  -- Reuse the same compose panel; the user can write a step-scoped refinement.
  M.compose({ refine_id = plan_id, focus_step = step_id })
end

-- ============================================================================
-- Picker
-- ============================================================================

local function picker_buffer()
  local name = "nvime://plans"
  local bufnr = find_buffer(name)
  if not bufnr then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "nvime"
  return bufnr
end

close_picker = function()
  local panel = state.panels.plan_picker
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_close, panel.winid, true)
  end
  state.panels.plan_picker = nil
  close_backdrop("picker")
end

refresh_picker = function()
  local panel = state.panels.plan_picker
  if not panel or not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
    return
  end
  M.refresh()
  local plans = M.plans()
  local lines = {}
  local marks = {}
  local row_index = {}

  local function push(line, hl, line_data)
    -- Same defense as render_plan_lines.push: plan.title or active_run.title
    -- may contain embedded newlines from agent-authored JSON.
    line = tostring(line or ""):gsub("\r", ""):gsub("\n", " ↵ ")
    lines[#lines + 1] = line
    if hl then
      marks[#marks + 1] = { row = #lines - 1, hl = hl, line = true }
    end
    if line_data then
      row_index[#lines] = line_data
    end
    return #lines - 1
  end

  local function mark_range(row, col_start, col_end, hl)
    marks[#marks + 1] = { row = row, hl = hl, col_start = col_start, col_end = col_end }
  end

  push("")
  local brand_glyph = glyph_or_bar("brand", " ")
  local header_row = push("  " .. brand_glyph .. " PLANS ", "NvimePlanHeading")
  mark_range(header_row, 2, 2 + #brand_glyph, "NvimeSection")
  push(string.format("  %d plan(s) in %s", #plans, plans_dir()), "NvimePlanWhy")
  push("  " .. string.rep("─", 76), "NvimePlanRule")
  push("")

  -- Active-run row at the very top: shows the in-flight (or just-finished)
  -- plan author run so the user sees it in the picker without having to
  -- remember a separate command.
  local active = state.plan and state.plan.active_run
  if active then
    local elapsed = os.time() - (active.started_at or os.time())
    local elapsed_label
    if elapsed < 60 then
      elapsed_label = elapsed .. "s"
    else
      elapsed_label = math.floor(elapsed / 60) .. "m " .. (elapsed % 60) .. "s"
    end
    local status_word, status_hl_active, icon
    if active.finished_at then
      if active.status == "ok" then
        status_word = "drafted"
        status_hl_active = "NvimePlanStepDone"
        icon = ui.icon("success") ~= "" and ui.icon("success") or "v"
      elseif active.status == "failed" then
        status_word = "failed"
        status_hl_active = "NvimePlanStepBlocked"
        icon = ui.icon("error") ~= "" and ui.icon("error") or "x"
      else
        status_word = active.status or "finished"
        status_hl_active = "NvimePlanWhy"
        icon = "·"
      end
    else
      status_word = "drafting"
      status_hl_active = "NvimePlanStepProgress"
      icon = ui.icon("active") ~= "" and ui.icon("active") or "*"
    end
    local title = active.title or "(plan author run)"
    local id_label = active.plan_id and (" " .. active.plan_id .. " ") or " new "
    local row_text = "  " .. icon .. "  " .. id_label .. "  " .. title
    local row = push(row_text, nil, { active_run = true })
    mark_range(row, 2, 2 + #icon, status_hl_active)
    local idx_start = 2 + #icon + 2
    mark_range(
      row,
      idx_start,
      idx_start + #id_label,
      status_hl_active == "NvimePlanStepProgress" and "NvimePlanStepIndex"
        or (status_hl_active == "NvimePlanStepDone" and "NvimePlanStepIndexDone" or "NvimePlanStepIndexBlocked")
    )
    local title_start = idx_start + #id_label + 2
    mark_range(row, title_start, #row_text, "NvimePlanIntent")

    local provider_label = active.provider or "?"
    local refine_suffix = active.refine_id and (" · refining " .. active.refine_id) or ""
    local meta = string.format(
      "        %s · %s%s · elapsed %s · <CR> to view",
      status_word,
      provider_label,
      refine_suffix,
      elapsed_label
    )
    push(meta, "NvimePlanMeta")
    push("  " .. string.rep("─", 76), "NvimePlanRule")
    push("")
  end

  if #plans == 0 then
    push("    (no plans yet — press n to draft one)", "NvimePlanWhy")
    push("")
  else
    for index, plan in ipairs(plans) do
      local status = plan_overall_status(plan)
      local c = counts_for_plan(plan)
      local id_label = " " .. (plan.id or "?") .. " "
      local title = plan.title or "(untitled)"
      local row_text = "  " .. status_icon(status) .. "  " .. id_label .. "  " .. title
      local row = push(row_text, nil, { plan_id = plan.id, index = index })
      local icon = status_icon(status)
      mark_range(row, 2, 2 + #icon, status_hl(status))
      local idx_start = 2 + #icon + 2
      mark_range(row, idx_start, idx_start + #id_label, status_index_hl(status))
      local title_start = idx_start + #id_label + 2
      mark_range(row, title_start, #row_text, "NvimePlanIntent")

      local bar_text, segments = progress_bar(plan, 28)
      local meta_prefix = "        "
      local meta = string.format(
        "%s%s   %d/%d done · updated %s",
        meta_prefix,
        bar_text,
        c.done,
        c.total,
        ui.relative_time(plan.updated_at or plan.created_at or 0)
      )
      local meta_row = push(meta)
      local cursor = #meta_prefix
      for _, seg in ipairs(segments) do
        local seg_bytes = #seg[1]
        mark_range(meta_row, cursor, cursor + seg_bytes, seg[2])
        cursor = cursor + seg_bytes
      end
      mark_range(meta_row, cursor, #meta, "NvimePlanMeta")
      push("")
    end
  end

  push("  " .. string.rep("─", 76), "NvimePlanRule")
  push("    <CR> open    n new    R refine    dd delete    r refresh    q close", "NvimePlanFooter")
  push("")

  local bufnr = panel.bufnr
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, PICKER_NS, 0, -1)
  ui.ensure_highlights()
  for _, mark in ipairs(marks) do
    local line = lines[mark.row + 1] or ""
    if mark.line then
      vim.api.nvim_buf_set_extmark(bufnr, PICKER_NS, mark.row, 0, {
        end_col = #line,
        hl_group = mark.hl,
        hl_eol = true,
      })
    else
      local col_start = math.max(0, math.min(mark.col_start or 0, #line))
      local col_end = math.max(col_start, math.min(mark.col_end or #line, #line))
      if col_end > col_start then
        vim.api.nvim_buf_set_extmark(bufnr, PICKER_NS, mark.row, col_start, {
          end_col = col_end,
          hl_group = mark.hl,
        })
      end
    end
  end
  vim.bo[bufnr].modifiable = false
  vim.b[bufnr].nvime_picker_rows = row_index
end

local function picker_row_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local rows = vim.b[bufnr].nvime_picker_rows or {}
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return rows[row]
end

local function plan_id_at_cursor()
  local entry = picker_row_at_cursor()
  if entry then
    return entry.plan_id
  end
  return nil
end

install_picker_keymaps = function(bufnr)
  -- Defensive: clear any stale buffer-local maps for the keys we own. The
  -- picker buffer is reused across opens, so a previously-deleted closure
  -- could otherwise still be held.
  for _, lhs in ipairs({ "<CR>", "n", "N", "R", "dd", "r", "q", "<Esc>" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
  local opts = { buffer = bufnr, silent = true, nowait = true }

  vim.keymap.set("n", "<CR>", function()
    local entry = picker_row_at_cursor()
    if not entry then
      return
    end
    if entry.active_run then
      -- The active-run row jumps to the run panel so the user can watch
      -- streaming or scroll the just-finished output.
      close_picker()
      M.reopen_run()
      return
    end
    if entry.plan_id then
      close_picker()
      M.open(entry.plan_id)
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: open" }))

  -- Both `n` and `N` (and a friendlier `<C-n>`) start a new plan compose
  -- session. Picker users may reach for either; netrw / other plugins'
  -- overrides on `n` are sidestepped by also offering `N`.
  local new_action = function()
    M.compose({})
  end
  vim.keymap.set("n", "n", new_action, vim.tbl_extend("force", opts, { desc = "nvime plan: new" }))
  vim.keymap.set("n", "N", new_action, vim.tbl_extend("force", opts, { desc = "nvime plan: new" }))
  vim.keymap.set("n", "<C-n>", new_action, vim.tbl_extend("force", opts, { desc = "nvime plan: new" }))

  vim.keymap.set("n", "R", function()
    local id = plan_id_at_cursor()
    if not id then
      return
    end
    M.replan(id)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: refine" }))

  vim.keymap.set("n", "dd", function()
    local id = plan_id_at_cursor()
    if not id then
      return
    end
    local choice = vim.fn.confirm("Delete plan " .. id .. "?", "&Yes\n&No", 2)
    if choice == 1 then
      M.delete(id)
      refresh_picker()
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: delete" }))

  vim.keymap.set("n", "r", function()
    refresh_picker()
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: refresh" }))

  vim.keymap.set("n", "q", close_picker, vim.tbl_extend("force", opts, { desc = "nvime plan: close" }))
  vim.keymap.set("n", "<Esc>", close_picker, vim.tbl_extend("force", opts, { desc = "nvime plan: close" }))
end

picker_winid = function()
  local panel = state.panels.plan_picker
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    return panel.winid
  end
  return nil
end

function M.picker()
  local bufnr = picker_buffer()
  local dim = dimensions()
  local brand = ui.icon("brand")
  local config = {
    relative = "editor",
    width = dim.width,
    height = dim.height,
    row = dim.row,
    col = dim.col,
    style = "minimal",
    border = dim.border,
    title = " " .. brand .. "  nvime plans ",
    title_pos = "center",
    footer = " <CR> open · n new · R refine · dd delete · r refresh · q close ",
    footer_pos = "center",
    zindex = 54,
    focusable = true,
  }
  local existing_winid = picker_winid()
  close_all_backdrops_except("picker")
  open_backdrop("picker")
  local winid
  if existing_winid then
    vim.api.nvim_win_set_buf(existing_winid, bufnr)
    vim.api.nvim_win_set_config(existing_winid, config)
    configure_window(existing_winid)
    winid = existing_winid
  else
    winid = vim.api.nvim_open_win(bufnr, true, config)
    configure_window(winid)
  end
  state.panels.plan_picker = { bufnr = bufnr, winid = winid }
  -- Force focus into the picker float; nvim_open_win(enter=true) is a hint
  -- that loses to other plugins' WinEnter shenanigans, so make it explicit.
  pcall(vim.api.nvim_set_current_win, winid)
  install_picker_keymaps(bufnr)
  refresh_picker()
end

-- ============================================================================
-- Compose panel (persistent draft buffer for the plan author intent)
-- ============================================================================

local COMPOSE_NS = vim.api.nvim_create_namespace("nvime.plan.compose")
local COMPOSE_BUFFER_NAME = "nvime://plan/compose"

local COMPOSE_TEMPLATE = {
  "# Title",
  "",
  "",
  "# Intent",
  "",
  "Describe what the plan should accomplish. Cite real files, line ranges, or",
  "IMPROVEMENTS.md sections when you can — the agent will ground its plan in",
  "actual code, not guesses. Multiline is fine; this buffer persists across",
  "close/reopen so you can iterate.",
  "",
  "# Notes (optional)",
  "",
  "",
}

local function compose_buffer()
  local existing = find_buffer(COMPOSE_BUFFER_NAME)
  if existing then
    return existing, false
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, COMPOSE_BUFFER_NAME)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, COMPOSE_TEMPLATE)
  return bufnr, true
end

local function compose_extract(bufnr)
  local raw = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local sections = {}
  local current = nil
  for _, line in ipairs(raw) do
    local heading = line:match("^#+%s*(.-)%s*$")
    if heading then
      local key = heading:lower():gsub(" .*$", "")
      current = key
      sections[current] = sections[current] or {}
    elseif current then
      table.insert(sections[current], line)
    end
  end
  local function clean(name)
    local lines = sections[name] or {}
    while #lines > 0 and lines[#lines]:match("^%s*$") do
      table.remove(lines)
    end
    while #lines > 0 and lines[1]:match("^%s*$") do
      table.remove(lines, 1)
    end
    return table.concat(lines, "\n")
  end
  return {
    title = clean("title"),
    intent = clean("intent"),
    notes = clean("notes"),
  }
end

local function compose_decorate(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  ui.ensure_highlights()
  vim.api.nvim_buf_clear_namespace(bufnr, COMPOSE_NS, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index, line in ipairs(lines) do
    if line:match("^#%s") then
      vim.api.nvim_buf_set_extmark(bufnr, COMPOSE_NS, index - 1, 0, {
        end_col = #line,
        hl_group = "NvimePlanHeading",
      })
    end
  end
  -- The key hints live in the float footer (compose_window_config). We
  -- deliberately do NOT repeat them as an in-buffer virt_line: the editable
  -- text wraps, so a fixed-width help line overflows the float and reads as a
  -- duplicate of the footer right below it.
end

local function compose_window_config(refining_id)
  local cfg = (state.config or {}).ui or {}
  local columns = vim.o.columns
  local lines = vim.o.lines
  local width = math.max(72, math.min(math.floor(columns * 0.74), columns - 4))
  local height = math.max(16, math.min(math.floor(lines * 0.62), lines - 4))
  local title
  if refining_id and refining_id ~= "" then
    title = " nvime plan compose · refining " .. refining_id .. " "
  else
    title = " nvime plan compose · new draft "
  end
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2 - 1)),
    col = math.max(0, math.floor((columns - width) / 2)),
    style = "minimal",
    border = cfg.border or "rounded",
    title = title,
    title_pos = "center",
    footer = " <C-s> submit · <C-c> cancel · q close · gC clear template ",
    footer_pos = "center",
    zindex = 54,
    focusable = true,
  }
end

local function close_compose_window()
  local panel = state.panels.plan_compose
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_close, panel.winid, true)
  end
  state.panels.plan_compose = nil
  close_backdrop("compose")
end

local function install_compose_keymaps(bufnr, refining_id)
  local opts = { buffer = bufnr, silent = true, nowait = true }

  vim.keymap.set({ "n", "i", "v" }, "<C-s>", function()
    if vim.fn.mode() ~= "n" then
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    end
    local extracted = compose_extract(bufnr)
    if extracted.title == "" and extracted.intent == "" then
      vim.notify("nvime: plan compose is empty", vim.log.levels.WARN)
      return
    end
    local intent_parts = {}
    if extracted.title ~= "" then
      intent_parts[#intent_parts + 1] = "Plan title: " .. extracted.title
    end
    if extracted.intent ~= "" then
      intent_parts[#intent_parts + 1] = extracted.intent
    end
    if extracted.notes ~= "" then
      intent_parts[#intent_parts + 1] = "Notes:\n" .. extracted.notes
    end
    local intent = table.concat(intent_parts, "\n\n")
    close_compose_window()
    M.create({ intent = intent, refine_id = refining_id })
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: submit compose" }))

  vim.keymap.set(
    "n",
    "q",
    close_compose_window,
    vim.tbl_extend("force", opts, { desc = "nvime plan: close compose (preserve draft)" })
  )
  vim.keymap.set(
    "n",
    "<Esc>",
    close_compose_window,
    vim.tbl_extend("force", opts, { desc = "nvime plan: close compose" })
  )
  vim.keymap.set("n", "<C-c>", function()
    -- If a plan author run is active, cancel it; otherwise close.
    if state.plan.active_run and state.plan.active_run.handle and state.plan.active_run.handle.kill then
      pcall(state.plan.active_run.handle.kill, state.plan.active_run.handle, "sigterm")
      vim.notify("nvime: cancelled plan author run", vim.log.levels.INFO)
    else
      close_compose_window()
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: cancel running / close compose" }))

  -- Use gC (not gx — vim 0.10+ ships a global gx that calls vim.ui.open which
  -- on some systems spawns an external terminal/browser. We unconditionally
  -- delete any existing buffer-local gx so it falls through to the global
  -- handler only when the user really wants to open a URL outside compose;
  -- inside compose, gx is intentionally a no-op to avoid surprises.)
  pcall(vim.keymap.del, "n", "gx", { buffer = bufnr })
  vim.keymap.set("n", "gx", "<Nop>", vim.tbl_extend("force", opts, { desc = "nvime plan: gx disabled in compose" }))

  vim.keymap.set("n", "gC", function()
    local choice = vim.fn.confirm("Reset compose buffer to template?", "&Reset\n&Cancel", 2)
    if choice == 1 then
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, COMPOSE_TEMPLATE)
      compose_decorate(bufnr)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
    end
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: reset compose template" }))

  vim.keymap.set("n", "?", function()
    vim.notify(
      table.concat({
        "nvime plan compose:",
        "<C-s>  submit the draft and start the plan author agent",
        "<C-c>  cancel a running agent (or close if idle)",
        "q     close the float (your draft is preserved)",
        "gC    reset the buffer to the template",
        "Buffer is plain markdown; sections under '# Title', '# Intent', '# Notes' are extracted.",
      }, "\n"),
      vim.log.levels.INFO
    )
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: compose help" }))

  -- Keep decoration fresh as the buffer changes.
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      vim.schedule(function()
        compose_decorate(bufnr)
      end)
    end,
  })
end

function M.compose(opts)
  opts = opts or {}
  -- Close the picker if it's open so we don't stack zindex-54 floats with
  -- ambiguous focus order. Also closes the picker backdrop.
  close_picker()

  local bufnr, fresh = compose_buffer()

  -- Always force the buffer modifiable on (re)open. Reusing a hidden buffer
  -- from a prior session can leave it stale-locked.
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false

  if opts.refine_id and opts.refine_id ~= "" then
    -- Pre-fill from the existing plan when refining
    local plan = M.get(opts.refine_id)
    if plan and fresh then
      local seed = {
        "# Title",
        "",
        plan.title or "",
        "",
        "# Intent",
        "",
        "Refining " .. opts.refine_id .. ". Describe the changes you want — what to add,",
        "remove, re-order. The current plan body is below for reference.",
        "",
        "# Notes (current plan)",
        "",
      }
      vim.list_extend(seed, vim.split(plan.why or "", "\n", { plain = true }))
      seed[#seed + 1] = ""
      seed[#seed + 1] = "Steps:"
      for _, step in ipairs(plan.steps or {}) do
        seed[#seed + 1] = string.format("- step %d (%s): %s", step.id or 0, step.status or "?", step.intent or "")
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, seed)
    end
  end

  close_all_backdrops_except("compose")
  open_backdrop("compose")
  local existing = state.panels.plan_compose
  local config = compose_window_config(opts.refine_id)
  local winid
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_win_set_buf(existing.winid, bufnr)
    vim.api.nvim_win_set_config(existing.winid, config)
    configure_window(existing.winid)
    winid = existing.winid
  else
    winid = vim.api.nvim_open_win(bufnr, true, config)
    configure_window(winid)
  end
  state.panels.plan_compose = { bufnr = bufnr, winid = winid, refine_id = opts.refine_id }

  -- Force focus into the float — `enter=true` on nvim_open_win is a hint, not
  -- a guarantee, especially when an existing window of the same zindex is
  -- being replaced. Without this, the user's cursor stays in netrw / the
  -- previous buffer and they get the read-only banner from THAT buffer.
  pcall(vim.api.nvim_set_current_win, winid)

  install_compose_keymaps(bufnr, opts.refine_id)
  compose_decorate(bufnr)

  -- Position cursor at the title field on first open
  if fresh then
    pcall(vim.api.nvim_win_set_cursor, winid, { 3, 0 })
  end
end

function M.prompt_new()
  M.compose({})
end

-- ============================================================================
-- External entrypoints
-- ============================================================================

function M.command(args)
  args = args or {}
  local fargs = args.fargs or {}
  local provider_name = nil
  if fargs[1] == "claude" or fargs[1] == "codex" then
    provider_name = table.remove(fargs, 1)
  end
  if #fargs == 0 then
    M.picker()
    return
  end
  local sub = table.remove(fargs, 1)
  if sub == "new" or sub == "compose" then
    if #fargs == 0 then
      M.compose({})
    else
      -- Inline form: `:NvimePlan new <intent>` skips the compose buffer.
      local intent = table.concat(fargs, " ")
      M.create({ intent = intent, provider = provider_name })
    end
    return
  end
  if sub == "refresh" then
    M.refresh()
    if state.panels.plan_picker and state.panels.plan_picker.winid then
      refresh_picker()
    end
    return
  end
  if sub == "close" then
    M.close_all()
    return
  end
  if sub == "focus" then
    if not M.focus() then
      vim.notify("nvime: no open plan UI to focus", vim.log.levels.INFO)
    end
    return
  end
  if sub == "run-log" or sub == "log" or sub == "stream" then
    M.reopen_run()
    return
  end
  if sub == "open" or sub == "show" then
    if #fargs == 0 then
      vim.notify("nvime: usage `:NvimePlan open <id>`", vim.log.levels.ERROR)
      return
    end
    M.open(fargs[1])
    return
  end
  if sub == "run" then
    if #fargs < 1 then
      vim.notify("nvime: usage `:NvimePlan run <id> [step]`", vim.log.levels.ERROR)
      return
    end
    local plan_id = fargs[1]
    if #fargs >= 2 then
      M.execute_step(plan_id, fargs[2], { provider = provider_name })
    else
      M.execute_step(plan_id, M._next_pending_step(plan_id), { provider = provider_name })
    end
    return
  end
  if sub == "delete" then
    if #fargs < 1 then
      vim.notify("nvime: usage `:NvimePlan delete <id>`", vim.log.levels.ERROR)
      return
    end
    M.delete(fargs[1])
    return
  end
  if sub == "discuss" then
    if #fargs < 1 then
      vim.notify("nvime: usage `:NvimePlan discuss <id>`", vim.log.levels.ERROR)
      return
    end
    M.discuss(fargs[1])
    return
  end
  if sub == "add-test" or sub == "test" then
    if #fargs < 2 then
      vim.notify("nvime: usage `:NvimePlan add-test <plan-id> <step-id>`", vim.log.levels.ERROR)
      return
    end
    M.add_test_for_step(fargs[1], fargs[2], { provider = provider_name })
    return
  end
  if sub == "reset-session" or sub == "fresh" then
    if #fargs < 1 then
      vim.notify("nvime: usage `:NvimePlan reset-session <plan-id> [provider]`", vim.log.levels.ERROR)
      return
    end
    M.reset_session(fargs[1], fargs[2] or provider_name)
    return
  end
  -- Treat any unrecognized first arg as a plan id to open
  M.open(sub)
end

function M._next_pending_step(plan_id)
  local plan = M.get(plan_id)
  if not plan then
    return nil
  end
  for _, step in ipairs(plan.steps or {}) do
    if step_status(step) == "pending" then
      return step.id
    end
  end
  return nil
end

function M.complete_subcommands(_, line)
  local subs = {
    "new",
    "compose",
    "open",
    "run",
    "delete",
    "discuss",
    "refresh",
    "close",
    "focus",
    "run-log",
    "add-test",
    "reset-session",
  }
  local out = {}
  local plans = M.plans()
  for _, sub in ipairs(subs) do
    out[#out + 1] = sub
  end
  for _, plan in ipairs(plans) do
    out[#out + 1] = plan.id
  end
  return out
end

-- Public escape hatch: tear down every plan UI surface (floats + backdrops).
-- Useful when a backdrop gets stuck or you want to start clean.
function M.close_all()
  close_all_plan_ui()
end

-- Bring focus back to whichever plan UI float is currently open. Answers the
-- "<C-w>w doesn't reach the float" complaint when the user has navigated
-- away with another binding. Priority: run (active streaming) > compose >
-- picker > view. The run panel wins so the user always sees fresh agent
-- output even if they accidentally closed the float.
function M.focus()
  local order = { "plan_run", "plan_compose", "plan_picker", "plan" }
  for _, key in ipairs(order) do
    local panel = state.panels[key]
    if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
      pcall(vim.api.nvim_set_current_win, panel.winid)
      return true
    end
  end
  -- Special case: the run buffer may exist (with streaming output in it) but
  -- its window was closed. Reopen the float and refocus.
  local active = state.plan and state.plan.active_run
  if active and active.bufnr and vim.api.nvim_buf_is_valid(active.bufnr) then
    close_all_backdrops_except("run")
    open_backdrop("run")
    local winid = open_run_window(active.bufnr)
    install_run_panel_keymaps(active.bufnr)
    if winid then
      pcall(vim.api.nvim_set_current_win, winid)
    end
    return true
  end
  return false
end

-- Reopen the most recent run panel (active or finished) so the user can see
-- streaming output again after `:q`. Equivalent to focus() when there is a
-- run-panel buffer; otherwise no-op.
function M.reopen_run()
  local panel = state.panels.plan_run
  local bufnr = panel and panel.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    local active = state.plan and state.plan.active_run
    bufnr = active and active.bufnr
  end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    vim.notify("nvime: no run panel to reopen", vim.log.levels.INFO)
    return false
  end
  close_all_backdrops_except("run")
  open_backdrop("run")
  local winid = open_run_window(bufnr)
  install_run_panel_keymaps(bufnr)
  if winid then
    pcall(vim.api.nvim_set_current_win, winid)
  end
  return true
end

function M.statusline_components()
  local plans = M.plans()
  local total = #plans
  local in_progress = 0
  local done = 0
  for _, plan in ipairs(plans) do
    local s = plan_overall_status(plan)
    if s == "in_progress" then
      in_progress = in_progress + 1
    elseif s == "done" then
      done = done + 1
    end
  end
  return { total = total, in_progress = in_progress, done = done }
end

function M.format_id(number, slug)
  return format_id(number, slug)
end

function M.next_plan_number()
  return next_plan_number()
end

function M.slugify(text)
  return slugify(text)
end

function M.plans_dir()
  return plans_dir()
end

M._build_author_prompt = build_author_prompt

return M
