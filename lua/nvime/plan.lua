local agents = require("nvime.agents")
local audit = require("nvime.audit")
local git = require("nvime.git")
local keyhelp = require("nvime.keyhelp")
local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local SCHEMA_VERSION = 2
local PLAN_NS = vim.api.nvim_create_namespace("nvime.plan.view")
local PICKER_NS = vim.api.nvim_create_namespace("nvime.plan.picker")
local BACKDROP_NS = vim.api.nvim_create_namespace("nvime.plan.backdrop")
local STATUS_ORDER = { pending = 1, in_progress = 2, blocked = 3, done = 4, abandoned = 5 }
local STATUSES = { "pending", "in_progress", "done", "blocked", "abandoned" }

-- The g? / ? cheat-sheet for the plan view, grouped by intent. Mirrors the keys
-- bound in install_plan_view_keymaps so the help tracks the real mappings.
local function plan_help_sections()
  return {
    {
      heading = "Phase 0 · research",
      rows = {
        { "<CR>  ga", "agree to the plan → start phase 1 (scaffold TODOs)" },
        { "gu", "update plan — chat to revise it in place" },
        { "gr", "re-plan — full rewrite from a fresh brief" },
        { "gN", "reset the provider session" },
      },
    },
    {
      heading = "Navigate",
      rows = {
        { "]s  [s", "next / previous step" },
        { "o", "open the step's file" },
        { "c", "copy the step intent" },
      },
    },
    {
      heading = "Window",
      rows = {
        { "q  <Esc>", "close the plan view" },
        { "g?  ?", "toggle this help" },
      },
    },
  }
end

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
  -- v2 phased flow: status follows the phase, not per-step execution.
  --   merged → done; phase 1/2 (scaffold/implement) → in_progress;
  --   phase 0 (authored, awaiting agree) → pending.
  if plan.merged_branch or plan.completed_at then
    return "done"
  end
  if (tonumber(plan.phase) or 0) >= 1 then
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
  -- v2: the phased lane. A freshly authored plan (or a migrated v1) starts in
  -- phase 0 (research) until the user agrees; phases 1 (scaffold TODOs) and 2
  -- (implement) run through a linked Big Change worktree session.
  plan.phase = tonumber(plan.phase) or 0
  plan.phase0_agreed = plan.phase0_agreed == true
  plan.phase1_agreed = plan.phase1_agreed == true
  plan.bigchange_session_id = tonumber(plan.bigchange_session_id)
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
-- Phased flow (phase 0 research → phase 1 scaffold → phase 2 implement). These
-- reference each other and the plan view, so forward-declare them here.
local open_phase
local advance_to_implement
local finalize_plan
local agree_and_scaffold

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

  -- Status row: phased plans track their phase, not per-step execution, so the
  -- headline is the status word + when it last changed (the phase track below
  -- carries the visual progress).
  local status_word = status:gsub("_", " ")
  local status_line =
    string.format("  %s  %s  updated %s", status_icon(status), pad_right(status_word, 12), updated_label)
  push(status_line, status_hl(status))

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

  -- Phase track: research → scaffold → implement, with completed phases filled,
  -- the current phase lit, and future phases dimmed.
  do
    local phase = tonumber(plan.phase) or 0
    local labels = { [0] = "research", [1] = "scaffold", [2] = "implement" }
    local line, spans = "  ", {}
    for i = 0, 2 do
      local glyph = (i < phase and "●") or (i == phase and "◉") or "○"
      local start = #line
      line = line .. glyph .. " " .. labels[i]
      local hl = (i < phase and "NvimeStatusSuccess") or (i == phase and "NvimePlanHeading") or "NvimePlanWhy"
      spans[#spans + 1] = { start, #line, hl }
      if i < 2 then
        line = line .. "  →  "
      end
    end
    local track_row = push(line)
    for _, s in ipairs(spans) do
      mark_range(track_row, s[1], s[2], s[3])
    end
  end
  push_blank()
  push_rule()
  push_blank()

  -- Call to action for phase 0: agree to start scaffolding.
  do
    local hint = (plan.phase0_agreed == true) and "agreed — press <CR> / ga to resume phase 1 (scaffold)"
      or "press <CR> / ga to agree → phase 1: the agent scaffolds TODOs you review"
    push("  " .. glyph_or_bar("review", "  ") .. hint, "NvimePlanWhy")
    push_blank()
  end

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
  push("    <CR>/ga agree → scaffold      gu update plan      gr re-plan      gN reset session", "NvimePlanFooter")
  push("    ]s [s navigate    o open file    c copy intent    g? keys    q close", "NvimePlanFooter")
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
    footer = " <CR>/ga agree → scaffold · gu update · gr re-plan · ]s/[s nav · q close ",
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
  -- A plan owns a Big Change worktree session for its scaffold/implement phases.
  -- Refuse to delete while it is actively building (that would orphan a running
  -- agent), otherwise discard the session first so its worktree + store record
  -- don't outlive the plan.
  if plan.bigchange_session_id then
    local session = require("nvime.bigchange.store").get(plan.bigchange_session_id)
    if session and session.busy then
      vim.notify(
        "nvime plan: a build is still running for this plan — wait for it to finish before deleting",
        vim.log.levels.WARN
      )
      return false
    end
    if session then
      pcall(function()
        require("nvime.bigchange").discard(plan.bigchange_session_id)
      end)
    end
  end
  local dir = plan_dir_for(plan_id)
  pcall(vim.fn.delete, dir, "rf")
  audit.write({ event = "plan_deleted", plan_id = plan_id })
  M.refresh()
  save_index(M.plans())
  return true
end

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
  -- Navigation only (the `o` key): jump to the step's recorded start line,
  -- clamped to the file. The phased flow no longer applies patches here, so the
  -- old drift re-anchoring is unnecessary.
  local line1 = 1
  if type(range) == "table" then
    line1 = math.max(1, math.min(clamp_int(range.line1 or range[1], 1), total_lines))
  end
  vim.api.nvim_win_set_cursor(0, { line1, 0 })
  return true
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
  -- Phase 0's author keeps its continuity in author_provider_sessions (it runs
  -- in a temp workspace cwd). Reset that so the next refinement starts a fresh
  -- conversation; also clear the legacy provider_sessions bucket if present.
  plan.author_provider_sessions = plan.author_provider_sessions or {}
  plan.provider_sessions = plan.provider_sessions or {}
  local had
  if provider and provider ~= "" then
    had = plan.author_provider_sessions[provider] or plan.provider_sessions[provider]
    plan.author_provider_sessions[provider] = nil
    plan.provider_sessions[provider] = nil
    persist_plan(plan)
    if had then
      vim.notify("nvime plan: " .. plan.id .. " — fresh session for next " .. provider .. " run", vim.log.levels.INFO)
    else
      vim.notify("nvime plan: no " .. provider .. " session captured for this plan", vim.log.levels.INFO)
    end
  else
    plan.author_provider_sessions = {}
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

-- ============================================================================
-- Phased flow: phase 0 (research + agree) → 1 (scaffold TODOs) → 2 (implement)
-- ============================================================================
-- Phases 1 and 2 reuse the Big Change engine. The agent works in an isolated
-- git worktree: in phase 1 it writes INERT TODO scaffolding (reviewed at vibe so
-- you shape it freely / edit it directly / ask the agent to revise it); in phase
-- 2 it implements that scaffolding (reviewed at vibe or easy). The plan owns the
-- worktree session via plan.bigchange_session_id; the runtime review hooks
-- (difficulty + the M completion action) are re-established on every route-in,
-- so the link survives a restart.

local PHASE = { RESEARCH = 0, SCAFFOLD = 1, IMPLEMENT = 2 }

local function plan_phase(plan)
  return tonumber(plan and plan.phase) or 0
end
M._plan_phase = plan_phase

-- Render the plan as a compact markdown spec the worktree agent builds against.
local function plan_spec_markdown(plan)
  local lines = { "# " .. (plan.title or plan.id or "plan") }
  if plan.why and plan.why ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Why"
    lines[#lines + 1] = plan.why
  end
  if plan.files_estimated and #plan.files_estimated > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Files (estimated)"
    for _, f in ipairs(plan.files_estimated) do
      lines[#lines + 1] = "- " .. tostring(f)
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "## Ordered steps"
  for _, step in ipairs(plan.steps or {}) do
    local loc = step.file or "?"
    local rng = range_label(step)
    if rng and rng ~= "" then
      loc = loc .. " · " .. rng
    end
    lines[#lines + 1] = string.format("%d. [%s] %s", step.id or 0, loc, (step.intent or ""):gsub("\n", " "))
    if step.notes and step.notes ~= "" then
      lines[#lines + 1] = "   - notes: " .. step.notes:gsub("\n", " ")
    end
  end
  if plan.acceptance and #plan.acceptance > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "## Acceptance criteria"
    for _, a in ipairs(plan.acceptance) do
      local t = type(a) == "table" and (a.text or "") or tostring(a)
      if t ~= "" then
        lines[#lines + 1] = "- " .. t:gsub("\n", " ")
      end
    end
  end
  return table.concat(lines, "\n")
end
M._plan_spec_markdown = plan_spec_markdown

-- Phase 1 build prompt: write inert TODO scaffolding only.
local function scaffold_prompt(plan)
  return table.concat({
    "You are SCAFFOLDING a plan as TODO markers — NOT implementing it. You work in",
    "the current directory (an isolated git worktree) with full tool access.",
    "",
    "Lay down the SKELETON of the change the plan describes, as INERT scaffolding only:",
    "- At every site that will change, insert a comment `TODO(nvime): <what changes here & why>`",
    "  (one line, using the file's own comment syntax).",
    "- Create any NEW files the plan needs, containing only their TODO outline — plus empty",
    "  function / type / interface signatures or stubs where they pin the design.",
    "- Add type / struct / interface definitions or signatures when they clarify the design, but",
    "  with NO function bodies and NO behavior.",
    "",
    "HARD RULES:",
    "- Implement NO behavior. No logic, no real function bodies, no wiring that runs.",
    "- You may modify existing code ONLY by adding a TODO comment beside it — never",
    "  delete, move, or rewrite existing code.",
    "- Keep the repo parseable: a stub may error / pass / throw / return a zero value, but must",
    "  not change runtime behavior.",
    "- Do NOT git commit or git push. Leave everything in the working tree.",
    "- When done, output a SHORT (<= 5 line) summary of where you placed TODOs. No plan dump.",
    "",
    "<plan>",
    plan_spec_markdown(plan),
    "</plan>",
  }, "\n")
end
M._scaffold_prompt = scaffold_prompt

-- Phase 2 build prompt: implement the reviewed TODO scaffolding.
local function implement_prompt(plan)
  return table.concat({
    "You are IMPLEMENTING a plan whose TODO scaffolding already exists in this worktree.",
    "The user reviewed and may have HAND-EDITED the TODO comments and stubs — they are",
    "authoritative. You work in the current directory (an isolated git worktree) with full",
    "tool access.",
    "",
    "Requirements:",
    "- Read the current files first. Find every `TODO(nvime):` marker, implement it fully, and",
    "  REMOVE the marker once done.",
    "- Honor the user's edits to the scaffolding. Match the surrounding code's style and idioms.",
    "- Implement everything the plan asks for. Run the project's tests / build if present and fix",
    "  what you break.",
    "- Do NOT git commit or git push. Leave all changes in the working tree.",
    "- When done, output a SHORT (<= 5 line) summary of what you implemented. No plan dump.",
    "",
    "<plan>",
    plan_spec_markdown(plan),
    "</plan>",
  }, "\n")
end
M._implement_prompt = implement_prompt

local function bc_store()
  return require("nvime.bigchange.store")
end

-- The Big Change worktree session backing this plan's phases 1–2 (or nil).
local function linked_session(plan)
  if not plan or not plan.bigchange_session_id then
    return nil
  end
  return bc_store().get(plan.bigchange_session_id)
end
M._linked_session = linked_session

local function ensure_linked_session(plan)
  local store_bc = bc_store()
  local existing = linked_session(plan)
  if existing then
    return existing
  end
  local provider = (state.config and state.config.provider) or "claude"
  local session = store_bc.create({
    title = "Plan " .. (plan.id or "?") .. " · " .. (plan.title or "scaffold"),
    difficulty = "vibe",
    provider = provider,
  })
  session.plan_id = plan.id
  session.spec = plan_spec_markdown(plan)
  session.goal = plan.title
  -- Persist the session to disk BEFORE the plan references it. Otherwise a crash
  -- in the touch()-deferred-save window would leave plan.bigchange_session_id
  -- pointing at a session whose plan_id was never written — losing the back-link
  -- and misrouting it as a plain Big Change on the next load.
  store_bc.save_now()
  plan.bigchange_session_id = session.id
  persist_plan(plan)
  return session
end

-- (Re)establish the runtime review hooks for the current phase. These hold
-- functions, so they are never serialized — set fresh on every route-in. The
-- closures capture plan_id (a string) and re-fetch, so a persist/reload between
-- setting and firing can't strand a stale plan table.
local function set_review_hooks(plan, session)
  local plan_id = plan.id
  if plan_phase(plan) == PHASE.SCAFFOLD then
    session.review_prompt_note =
      "The user may have hand-edited the TODO scaffolding directly in this worktree; the worktree files are the source of truth — read them before revising."
    session.review_complete = {
      label = "advance → implement",
      run = function()
        advance_to_implement(plan_id)
      end,
    }
  else
    session.review_prompt_note = nil
    session.review_complete = {
      label = "merge → branch",
      run = function(sess, rerender)
        require("nvime.bigchange.merge").start(sess, function()
          finalize_plan(plan_id)
          if rerender then
            rerender()
          end
        end)
      end,
    }
  end
end

-- Kick the worktree build for the current phase (scaffold or implement). On
-- completion the Big Change build flow extracts review blocks and opens the
-- review with the hooks we set on the session.
local function start_phase_build(plan, session)
  local build = require("nvime.bigchange.build")
  -- session.spec was set from the plan at link time (used only as a label in the
  -- Big Change picker); the build prompt below derives its own spec from `plan`,
  -- so there is nothing to recompute here.
  local opts
  if plan_phase(plan) == PHASE.SCAFFOLD then
    opts = {
      prompt = scaffold_prompt(plan),
      heading = ui.icon("brand") .. "  Plan " .. (plan.id or "") .. " · scaffolding TODOs (phase 1)",
      building_label = "Agent is laying down TODO scaffolding (inert — no behavior). This may take a moment…",
    }
    -- Remind the reviewer that phase 1 is scaffolding-only: anything that looks
    -- like real behavior is a bug to send back, not to approve.
    vim.notify(
      "nvime plan phase 1: review the TODO scaffolding — it must be inert (comments / stubs / type defs). "
        .. "Press r to send back any real behavior; M to advance to implement.",
      vim.log.levels.INFO
    )
  else
    opts = {
      prompt = implement_prompt(plan),
      heading = ui.icon("brand") .. "  Plan " .. (plan.id or "") .. " · implementing (phase 2)",
      building_label = "Agent is implementing the reviewed TODOs full-auto. This may take a while…",
    }
  end
  build.start(session, opts)
end

-- Route into phases 1/2: resume an in-flight build, reopen an existing review,
-- or start a fresh build. Hooks are always re-established first.
open_phase = function(plan)
  local store_bc = bc_store()
  local session = ensure_linked_session(plan)
  -- ensure_linked_session may have persisted + reloaded the plan list; re-fetch
  -- so we operate on the current on-disk copy.
  plan = M.get(plan.id) or plan
  set_review_hooks(plan, session)
  store_bc.set_active(session.id)
  if session.busy then
    require("nvime.bigchange.build").open(session)
    return
  end
  if session.blocks and #session.blocks > 0 then
    require("nvime.bigchange.review").open(session)
    return
  end
  start_phase_build(plan, session)
end
M._open_phase = open_phase

-- Transition phase 1 → 2 with the chosen review strictness (no → vibe,
-- yes → easy), then implement the reviewed scaffolding. The require-understanding
-- question is asked by advance_to_implement; this does the state change so tests
-- can drive it directly.
local function enter_implement(plan_id, require_understanding)
  local plan = M.get(plan_id)
  if not plan then
    return
  end
  local session = linked_session(plan)
  if not session then
    return
  end
  local store_bc = bc_store()
  plan.require_understanding = require_understanding == true
  plan.phase1_agreed = true
  plan.phase = PHASE.IMPLEMENT
  persist_plan(plan)
  plan = M.get(plan_id) or plan
  session.difficulty = plan.require_understanding and "easy" or "vibe"
  -- Fresh review for the implementation diff. Empty table (not nil) keeps the
  -- field type-consistent with store.normalize; the next build's blocks.extract
  -- repopulates it with the implementation blocks.
  session.blocks = {}
  store_bc.touch(session)
  set_review_hooks(plan, session)
  require("nvime.bigchange.review").close()
  start_phase_build(plan, session)
end
M._enter_implement = enter_implement

-- Phase 1 → 2: ask the "require understanding?" question, then implement.
advance_to_implement = function(plan_id)
  local plan = M.get(plan_id)
  if not plan then
    return
  end
  if not linked_session(plan) then
    return
  end
  local items = {
    { req = false, label = "No  — vibe: review without a comprehension gate (approve to clear)" },
    { req = true, label = "Yes — easy: explain each block at a light bar (≥ 40%)" },
  }
  vim.ui.select(items, {
    prompt = "Phase 2 review — require understanding?",
    format_item = function(it)
      return it.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    enter_implement(plan_id, choice.req)
  end)
end

-- Phase 2 merge landed: record the branch on the plan and announce it.
finalize_plan = function(plan_id)
  local plan = M.get(plan_id)
  if not plan then
    return
  end
  local session = linked_session(plan)
  plan.merged_branch = session and session.merged_branch
  plan.completed_at = now_ts()
  persist_plan(plan)
  vim.notify(
    string.format(
      "nvime plan %s: implemented & merged onto '%s' (unstaged). Use git to stage & commit.",
      plan.id,
      (session and session.merged_branch) or "?"
    ),
    vim.log.levels.INFO
  )
end
M._finalize_plan = function(plan_id)
  return finalize_plan(plan_id)
end

-- Transition phase 0 → 1 and start the scaffold build. No confirmation; the
-- view binding asks first via agree_and_scaffold. Exposed for tests.
local function enter_scaffold(plan_id)
  local plan = M.get(plan_id)
  if not plan then
    return
  end
  plan.phase0_agreed = true
  plan.phase = PHASE.SCAFFOLD
  persist_plan(plan)
  plan = M.get(plan_id) or plan
  close_plan_view()
  open_phase(plan)
end
M._enter_scaffold = enter_scaffold

-- Phase 0 → 1: the agree gate. Confirm, then enter the scaffold phase.
agree_and_scaffold = function(plan_id)
  local plan = M.get(plan_id)
  if not plan then
    return
  end
  if plan_phase(plan) ~= PHASE.RESEARCH then
    open_phase(plan)
    return
  end
  if not plan.steps or #plan.steps == 0 then
    vim.notify("nvime plan: nothing to scaffold yet — author a plan first", vim.log.levels.WARN)
    return
  end
  local choice = vim.fn.confirm(
    "Agree to this plan and start phase 1?\nThe agent writes TODO scaffolding (no behavior) in an isolated worktree you then review.",
    "&Agree & scaffold\n&Cancel",
    1
  )
  if choice ~= 1 then
    return
  end
  enter_scaffold(plan_id)
end
M.agree = agree_and_scaffold

install_plan_view_keymaps = function(bufnr, plan_id, step_index)
  -- Defensive: clear any stale buffer-local maps so reusing the buffer across
  -- opens doesn't leave dead closures, and so a global `ga`/`gx` (vim.ui.open
  -- in nvim 0.10+) can't sneak through if a previous install_* removed and
  -- failed to re-set our binding.
  for _, lhs in ipairs({
    "<CR>",
    "ga",
    "]s",
    "[s",
    "o",
    "c",
    "gu",
    "gr",
    "gN",
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

  -- The phase-0 view's primary action: agree to the plan and start phase 1
  -- (the agent writes TODO scaffolding in an isolated worktree you then review).
  local function agree()
    agree_and_scaffold(plan_id)
  end
  vim.keymap.set("n", "<CR>", agree, vim.tbl_extend("force", opts, { desc = "nvime plan: agree & scaffold (phase 1)" }))
  vim.keymap.set("n", "ga", agree, vim.tbl_extend("force", opts, { desc = "nvime plan: agree & scaffold (phase 1)" }))

  vim.keymap.set("n", "gN", function()
    -- "g new-session" — clear the plan's captured author session so the next
    -- refinement starts fresh. Useful when the research conversation has gotten
    -- too long or off-track.
    local plan = M.get(plan_id)
    if not plan then
      return
    end
    local provider_name = (state.config and state.config.provider) or "claude"
    M.reset_session(plan_id, provider_name)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: reset provider session" }))

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

  vim.keymap.set("n", "gu", function()
    M.update_chat(plan_id)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: update plan (chat)" }))

  vim.keymap.set("n", "gr", function()
    M.replan(plan_id)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: re-plan (full rewrite)" }))

  vim.keymap.set("n", "q", close_plan_view, vim.tbl_extend("force", opts, { desc = "nvime plan: close" }))
  vim.keymap.set("n", "<Esc>", close_plan_view, vim.tbl_extend("force", opts, { desc = "nvime plan: close" }))
  local function show_plan_help()
    keyhelp.toggle({
      title = "plan keys",
      sections = plan_help_sections(),
      parent_winid = vim.api.nvim_get_current_win(),
    })
  end
  vim.keymap.set("n", "?", show_plan_help, vim.tbl_extend("force", opts, { desc = "nvime plan: help" }))
  vim.keymap.set("n", "g?", show_plan_help, vim.tbl_extend("force", opts, { desc = "nvime plan: help" }))
end

function M.open(plan_id)
  M.refresh()
  local plan = M.get(plan_id)
  if not plan then
    vim.notify("nvime: unknown plan " .. tostring(plan_id), vim.log.levels.ERROR)
    return
  end
  -- Phases 1–2 live in the linked Big Change worktree session (scaffold review,
  -- implement review). Phase 0 is the research plan with the agree gate.
  if plan_phase(plan) >= PHASE.SCAFFOLD then
    open_phase(plan)
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
  "Do not narrate tool use, investigation progress, or status updates. The VERY FIRST characters of your stdout MUST be the literal token NVIME_PLAN — no preamble, no conclusion, no tooling notes, not one sentence before it. Record any caveats (e.g. which test runner or linter you picked) inside the plan's `notes`/`why` fields, never as prose before the marker.",
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
  "  6. Emit ONE machine-readable marker — with NOTHING before it — as your entire concluding output (no other prose):",
  "",
  "NVIME_PLAN",
  "```json",
  '{ "id": "<plan-id>", "summary": "<one-sentence what+why>", "step_count": <N>, "files_estimated": ["..."] }',
  "```",
  "",
  "Plan id format: `NNNN-<kebab-slug>`. Pick the next free 4-digit number by listing `.nvime/plans/`.",
  "",
  "plan.json schema (version 2):",
  "{",
  '  "version": 2,',
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
  local response = {} -- on_text only (the agent's answer; carries the NVIME_PLAN marker)
  local all_output = {} -- on_text + on_progress (used to detect resume failures)
  -- Two output sinks. The default author flow streams into the run-log float.
  -- When opts.on_stream is given (the "update plan" chat), the caller captures
  -- the agent's output into its transcript and we open no float. opts.on_complete
  -- likewise lets the caller re-render its own surface instead of M.open.
  local run_bufnr
  if not opts.on_stream then
    run_bufnr = format_run_log()
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
  end
  local function emit(text)
    if opts.on_stream then
      opts.on_stream(text)
    elseif run_bufnr then
      run_panel_append(text)
    end
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
      all_output[#all_output + 1] = text
      emit(text)
    end,
    on_progress = function(text)
      all_output[#all_output + 1] = text
      emit(text)
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
      emit("\n" .. string.rep("─", 78) .. "\n")

      local plan_id = nil
      local final_status = "ok"
      -- Stale-session self-recovery: when refining/updating, the provider may no
      -- longer have the resumed author session ("No conversation found with
      -- session ID: ..."). Clear the bad id and retry ONCE from a fresh
      -- conversation, so an expired (or pre-stable-workspace) session can't wedge
      -- the update.
      if
        result.code ~= 0
        and resume_session_id
        and not opts._fresh_retry
        and table.concat(all_output):lower():find("no conversation found", 1, true)
      then
        if opts.refine_id then
          local stale = M.get(opts.refine_id)
          if stale and stale.author_provider_sessions then
            stale.author_provider_sessions[provider] = nil
            persist_plan(stale)
          end
        end
        emit("[nvime] stored session expired — retrying with a fresh conversation…\n")
        if state.plan._tick_timer then
          pcall(state.plan._tick_timer.stop, state.plan._tick_timer)
          pcall(state.plan._tick_timer.close, state.plan._tick_timer)
          state.plan._tick_timer = nil
        end
        state.plan.active_run = nil
        local retry = vim.tbl_extend("force", {}, opts)
        retry._fresh_retry = true
        vim.schedule(function()
          M.create(retry)
        end)
        return
      end
      if result.code ~= 0 then
        final_status = "failed"
        emit("[nvime] plan author failed (code " .. tostring(result.code) .. ")\n")
      elseif #synced == 0 then
        final_status = "no_output"
        emit("[nvime] no plan files were written; the agent may have refused.\n")
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
        emit(string.format("[nvime] synced %d plan file(s)%s\n", #synced, plan_id and (" · plan " .. plan_id) or ""))
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
        if not opts.on_complete and plan_id and (plan_config().auto_open ~= false) then
          vim.defer_fn(function()
            close_run_window()
            M.open(plan_id)
          end, 250)
        end
      end

      -- The caller (e.g. the update-plan chat) re-renders its own surface.
      if opts.on_complete then
        pcall(opts.on_complete, plan_id, final_status)
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

-- ============================================================================
-- Update-plan chat (phase 0)
-- ============================================================================
-- A conversation to revise the plan IN PLACE — "rework step 2 to use a deque"
-- — instead of re-typing a whole brief. A tabpage with the live plan view on
-- the left and a single chat pane on the right (transcript with the message
-- input as its editable tail); each message resumes the author session, edits
-- plan.json, and re-renders the plan. (Major rewrites still go through
-- gr → re-plan, which re-authors from a fresh brief.)

local UPDATE_NS = vim.api.nvim_create_namespace("nvime.plan.update.scrollback")
-- Unsent input drafts, kept across close/reopen so q never loses your text.
local update_drafts = {}
local U = {
  plan_id = nil,
  tabpage = nil,
  plan_win = nil,
  plan_buf = nil,
  chat_win = nil,
  chat_buf = nil,
  input_start = 1, -- 1-based line where the editable input region begins
  busy = false,
  gen = 0, -- bumped on close; stale agent callbacks check it and bail
}

local function update_is_open()
  return U.tabpage and vim.api.nvim_tabpage_is_valid(U.tabpage)
end

local function chat_valid()
  return U.chat_buf and vim.api.nvim_buf_is_valid(U.chat_buf)
end

-- The unsent message: every line from the input marker to the end of the buffer.
local function current_input_lines()
  if not chat_valid() then
    return {}
  end
  local total = vim.api.nvim_buf_line_count(U.chat_buf)
  if U.input_start > total then
    return {}
  end
  return vim.api.nvim_buf_get_lines(U.chat_buf, U.input_start - 1, -1, false)
end

local function decorate_chat()
  local ok_render, render = pcall(require, "nvime.render")
  if ok_render and type(render.scrollback) == "function" then
    pcall(render.scrollback, U.chat_buf, UPDATE_NS)
  end
end

local function scroll_chat_bottom()
  if U.chat_win and vim.api.nvim_win_is_valid(U.chat_win) then
    pcall(vim.api.nvim_win_set_cursor, U.chat_win, { vim.api.nvim_buf_line_count(U.chat_buf), 0 })
  end
end

-- Append streamed text at the end of the chat buffer. Schedule-safe: agent
-- callbacks fire in a fast-event context where buffer writes are illegal.
local function chat_append(text)
  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(function()
      chat_append(text)
    end)
    return
  end
  if not chat_valid() then
    return
  end
  local cur = vim.api.nvim_buf_get_lines(U.chat_buf, 0, -1, false)
  local pieces = vim.split(text or "", "\n", { plain = true })
  vim.bo[U.chat_buf].modifiable = true
  cur[#cur] = (cur[#cur] or "") .. pieces[1]
  for i = 2, #pieces do
    cur[#cur + 1] = pieces[i]
  end
  vim.api.nvim_buf_set_lines(U.chat_buf, 0, -1, false, cur)
  vim.bo[U.chat_buf].modifiable = not U.busy
  decorate_chat()
  scroll_chat_bottom()
end

local function chat_line(line)
  chat_append((line or "") .. "\n")
end

-- Re-render the live plan view (left pane) from the latest on-disk plan.
local function render_update_plan()
  local plan = M.get(U.plan_id)
  if not plan then
    return
  end
  local buf = render_plan(plan, { open = false })
  U.plan_buf = buf
  if U.plan_win and vim.api.nvim_win_is_valid(U.plan_win) then
    vim.api.nvim_win_set_buf(U.plan_win, buf)
    configure_window(U.plan_win)
  end
end

local function update_winbar()
  if U.chat_win and vim.api.nvim_win_is_valid(U.chat_win) then
    vim.wo[U.chat_win].winbar = U.busy and "  updating the plan…"
      or "  type your change · <C-s> send · <C-c> cancel · q close"
  end
end

local function update_set_busy(on)
  U.busy = on
  if chat_valid() then
    vim.bo[U.chat_buf].modifiable = not on
  end
  update_winbar()
end

-- Open a fresh editable input region at the bottom (optionally pre-filled with a
-- saved draft) and record where it starts.
local function begin_input(seed)
  if not chat_valid() then
    return
  end
  local cur = vim.api.nvim_buf_get_lines(U.chat_buf, 0, -1, false)
  if (cur[#cur] or "") ~= "" then
    cur[#cur + 1] = ""
  end
  local start = #cur + 1
  local seed_lines = (seed and seed ~= "") and vim.split(seed, "\n", { plain = true }) or { "" }
  for _, l in ipairs(seed_lines) do
    cur[#cur + 1] = l
  end
  vim.bo[U.chat_buf].modifiable = true
  vim.api.nvim_buf_set_lines(U.chat_buf, 0, -1, false, cur)
  vim.bo[U.chat_buf].modifiable = not U.busy
  U.input_start = start
  if U.chat_win and vim.api.nvim_win_is_valid(U.chat_win) then
    pcall(vim.api.nvim_win_set_cursor, U.chat_win, { #cur, #(cur[#cur] or "") })
  end
end

-- Remember the unsent draft so closing/reopening never loses it.
local function save_draft()
  if not U.plan_id then
    return
  end
  local txt = vim.trim(table.concat(current_input_lines(), "\n"))
  update_drafts[U.plan_id] = (txt ~= "") and txt or nil
end

local function update_close()
  save_draft()
  -- Invalidate any in-flight run (its callbacks check U.gen) and stop a runaway
  -- author so its stream can't leak into a later session.
  U.gen = U.gen + 1
  if U.busy then
    local active = state.plan and state.plan.active_run
    if active and active.handle and active.handle.kill then
      pcall(active.handle.kill, active.handle, "sigterm")
    end
    U.busy = false
  end
  if update_is_open() then
    pcall(function()
      vim.api.nvim_set_current_tabpage(U.tabpage)
      vim.cmd("tabclose")
    end)
  end
  U.tabpage = nil
end

local function update_cancel()
  local active = state.plan and state.plan.active_run
  if U.busy and active and active.handle and active.handle.kill then
    pcall(active.handle.kill, active.handle, "sigterm")
    -- Don't clear busy here: the agent exits asynchronously and on_complete
    -- (from on_exit) is what unlocks input. Clearing now would let a second send
    -- double-run the author against the still-dying process.
  end
end

local function update_submit()
  if U.busy then
    vim.notify("nvime plan: an update is still running — <C-c> to cancel", vim.log.levels.INFO)
    return
  end
  if not chat_valid() then
    return
  end
  local text = vim.trim(table.concat(current_input_lines(), "\n"))
  if text == "" then
    return
  end
  update_drafts[U.plan_id] = nil

  -- Convert the input region into a sent "you" turn.
  local block = { "▌ you" }
  for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
    block[#block + 1] = "  " .. l
  end
  block[#block + 1] = ""
  block[#block + 1] = "▌ author"
  vim.bo[U.chat_buf].modifiable = true
  vim.api.nvim_buf_set_lines(U.chat_buf, U.input_start - 1, -1, false, block)
  update_set_busy(true)
  decorate_chat()
  scroll_chat_bottom()

  local gen = U.gen
  M.create({
    intent = text,
    refine_id = U.plan_id,
    on_stream = function(t)
      if gen == U.gen then
        chat_append(t)
      end
    end,
    on_complete = function(_, status)
      if gen ~= U.gen then
        return -- a stale run from a closed/superseded session
      end
      update_set_busy(false)
      chat_line("")
      if status == "ok" then
        chat_line("✓ plan updated")
        render_update_plan()
      else
        chat_line("⚠ no change to the plan (" .. tostring(status) .. ") — try rephrasing")
      end
      begin_input(nil)
      if U.chat_win and vim.api.nvim_win_is_valid(U.chat_win) then
        pcall(vim.api.nvim_set_current_win, U.chat_win)
        vim.cmd("startinsert")
      end
    end,
  })
end

local function update_help_sections()
  return {
    {
      heading = "Update plan",
      rows = {
        { "<C-s>", "send your change to the author (resumes the session)" },
        { "<C-c>", "cancel the in-flight update" },
      },
    },
    {
      heading = "Window",
      rows = {
        { "<Tab>", "toggle between the chat and the plan pane" },
        { "q", "close (your unsent draft is kept)" },
        { "g?", "toggle this help" },
      },
    },
  }
end

local function update_help()
  keyhelp.toggle({
    title = "update plan keys",
    sections = update_help_sections(),
    parent_winid = vim.api.nvim_get_current_win(),
  })
end

local function focus_other()
  local target = (vim.api.nvim_get_current_win() == U.chat_win) and U.plan_win or U.chat_win
  if target and vim.api.nvim_win_is_valid(target) then
    vim.api.nvim_set_current_win(target)
  end
end

local function install_update_keymaps()
  -- Chat pane (the single transcript+input buffer): send / cancel from insert
  -- and normal mode; q closes (the draft is saved first).
  local copts = { buffer = U.chat_buf, silent = true, nowait = true }
  vim.keymap.set({ "n", "i" }, "<C-s>", update_submit, copts)
  vim.keymap.set({ "n", "i" }, "<C-c>", update_cancel, copts)
  vim.keymap.set("n", "q", update_close, copts)
  vim.keymap.set("n", "g?", update_help, copts)
  vim.keymap.set("n", "<Tab>", focus_other, copts)
  -- Plan pane (read-only reference): close, hop back to the chat, help.
  local popts = { buffer = U.plan_buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", update_close, popts)
  vim.keymap.set("n", "g?", update_help, popts)
  vim.keymap.set("n", "<Tab>", focus_other, popts)
end

function M.update_chat(plan_id)
  local plan = M.get(plan_id)
  if not plan then
    vim.notify("nvime: unknown plan " .. tostring(plan_id), vim.log.levels.ERROR)
    return
  end
  -- Updating only makes sense before the plan is committed to code (phase 0).
  if plan_phase(plan) >= PHASE.SCAFFOLD then
    vim.notify("nvime plan: past phase 0 — opening its current phase instead", vim.log.levels.INFO)
    open_phase(plan)
    return
  end
  if update_is_open() and U.plan_id == plan_id then
    vim.api.nvim_set_current_tabpage(U.tabpage)
    if U.chat_win and vim.api.nvim_win_is_valid(U.chat_win) then
      vim.api.nvim_set_current_win(U.chat_win)
    end
    return
  end
  if update_is_open() then
    update_close()
  end
  U.plan_id = plan_id
  U.busy = false

  vim.cmd("tabnew")
  U.tabpage = vim.api.nvim_get_current_tabpage()
  -- The initial window becomes the chat pane; split the plan pane off to the left.
  U.chat_win = vim.api.nvim_get_current_win()
  vim.cmd("topleft vsplit")
  U.plan_win = vim.api.nvim_get_current_win()
  pcall(vim.api.nvim_win_set_width, U.plan_win, math.max(56, math.floor(vim.o.columns * 0.5)))
  U.plan_buf = render_plan(plan, { open = false })
  vim.api.nvim_win_set_buf(U.plan_win, U.plan_buf)
  configure_window(U.plan_win)

  ui.ensure_highlights()
  U.chat_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[U.chat_buf].bufhidden = "wipe"
  vim.bo[U.chat_buf].filetype = "nvime"
  vim.api.nvim_win_set_buf(U.chat_win, U.chat_buf)
  ui.configure_panel_window(U.chat_win, { wrap = true, cursorline = false })
  -- Persist the draft if the tab is closed by any means (not just q).
  vim.api.nvim_create_autocmd("BufWinLeave", { buffer = U.chat_buf, callback = save_draft })

  chat_line("  " .. ui.icon("brand") .. "  update plan · " .. (plan.title or plan_id))
  chat_line("  Tell the author what to change — e.g. “rework step 2 to use a deque, and")
  chat_line("  drop step 4”. It edits the plan in place; the plan pane refreshes.")
  chat_line("  <C-s> send · q close · gr (in the plan pane) re-plans from scratch.")
  chat_line(string.rep("─", 58))
  begin_input(update_drafts[plan_id])

  install_update_keymaps()
  update_set_busy(false)
  vim.api.nvim_set_current_win(U.chat_win)
  vim.cmd("startinsert")
end
M.update = M.update_chat

-- Back-compat: the old discuss/refine entry now opens the update chat.
function M.discuss(plan_id, _step_id)
  M.update_chat(plan_id)
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
  push("    <CR> open    n new    R re-plan    dd delete    r refresh    q close", "NvimePlanFooter")
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
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: re-plan (full rewrite)" }))

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
    footer = " <CR> open · n new · R re-plan · dd delete · r refresh · q close ",
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
  if sub == "agree" or sub == "scaffold" then
    if #fargs < 1 then
      vim.notify("nvime: usage `:NvimePlan agree <id>`", vim.log.levels.ERROR)
      return
    end
    M.agree(fargs[1])
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
  if sub == "update" or sub == "discuss" then
    if #fargs < 1 then
      vim.notify("nvime: usage `:NvimePlan update <id>`", vim.log.levels.ERROR)
      return
    end
    M.update_chat(fargs[1])
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

function M.complete_subcommands(_, line)
  local subs = {
    "new",
    "compose",
    "open",
    "agree",
    "delete",
    "update",
    "refresh",
    "close",
    "focus",
    "run-log",
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
