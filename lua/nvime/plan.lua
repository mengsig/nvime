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
  fd:close()
  if not write_ok then
    return false, write_err
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
  if c.done == c.total then
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
  if c.done == c.total then
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

local function close_backdrop(name)
  local key = "plan_" .. name
  local backdrop = state.panels[key]
  if backdrop and backdrop.winid and vim.api.nvim_win_is_valid(backdrop.winid) then
    pcall(vim.api.nvim_win_close, backdrop.winid, true)
  end
  state.panels[key] = nil
end

local function open_backdrop(name)
  local cfg = (state.config or {}).ui or {}
  if cfg.backdrop == false then
    close_backdrop(name)
    return
  end
  local key = "plan_" .. name
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
  local segments = {}
  if done > 0 then
    segments[#segments + 1] = { string.rep("█", done), "NvimePlanProgressFill" }
  end
  if active > 0 then
    segments[#segments + 1] = { string.rep("▓", active), "NvimePlanProgressActive" }
  end
  if blocked > 0 then
    segments[#segments + 1] = { string.rep("▒", blocked), "NvimePlanStepBlocked" }
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

local function render_plan_lines(plan)
  local lines = {}
  local marks = {} -- { row, hl, line = true } | { row, hl, col_start, col_end } | { row, virt = true, chunks = {...} }
  local step_index = {} -- step_id -> { first_row, last_row }

  local function push(line, hl)
    lines[#lines + 1] = line
    if hl then
      marks[#marks + 1] = { row = #lines - 1, hl = hl, line = true }
    end
    return #lines - 1
  end

  local function mark_range(row, col_start, col_end, hl)
    marks[#marks + 1] = { row = row, hl = hl, col_start = col_start, col_end = col_end }
  end

  local function push_blank()
    push("")
  end

  local function push_rule()
    push("  " .. string.rep("─", 76), "NvimePlanRule")
  end

  local title = plan.title or plan.id or "(unnamed plan)"
  local status = plan_overall_status(plan)
  local c = counts_for_plan(plan)
  local updated = plan.updated_at or plan.created_at
  local updated_label = updated and ui.relative_time(updated) or "new"

  push_blank()
  -- Header line: "  ┃ PLAN ┃  0001-audit-prune                           v0.3.0  •  updated 5m"
  local id_label = " " .. (plan.id or "?") .. " "
  local label = "  ▎  PLAN " .. id_label
  local row = push(label, "NvimePlanHeading")
  -- Color the id segment as a badge
  local prefix = "  ▎  PLAN "
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
    push("  ▎ WHY", "NvimePlanHeading")
    for _, paragraph in ipairs(vim.split(plan.why, "\n", { plain = true })) do
      push("      " .. paragraph, "NvimePlanWhy")
    end
    push_blank()
  end

  if plan.acceptance and #plan.acceptance > 0 then
    push("  ▎ ACCEPTANCE", "NvimePlanHeading")
    for _, item in ipairs(plan.acceptance) do
      local itxt = type(item) == "table" and (item.text or "") or tostring(item)
      local istatus = type(item) == "table" and item.status or "pending"
      local arow = push("      " .. status_icon(istatus) .. "  " .. itxt)
      mark_range(arow, 6, 6 + #status_icon(istatus), status_hl(istatus))
      mark_range(arow, 6 + #status_icon(istatus), #(lines[arow + 1] or ""), "NvimePlanWhy")
    end
    push_blank()
  end

  if plan.files_estimated and #plan.files_estimated > 0 then
    push("  ▎ FILES", "NvimePlanHeading")
    for _, file in ipairs(plan.files_estimated) do
      push("      " .. tostring(file), "NvimePlanFile")
    end
    push_blank()
  end

  push("  ▎ STEPS", "NvimePlanHeading")
  push_blank()

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

    -- File and range
    local file_line = "         " .. (step.file or "?") .. "  " .. range_label(step)
    local file_row = push(file_line)
    mark_range(file_row, 9, 9 + #(step.file or "?"), "NvimePlanFile")
    mark_range(file_row, 9 + #(step.file or "?"), #file_line, "NvimePlanMeta")

    if step.depends_on and #step.depends_on > 0 then
      local labels = {}
      for _, dep in ipairs(step.depends_on) do
        labels[#labels + 1] = "#" .. tostring(dep)
      end
      push("         deps " .. table.concat(labels, " "), "NvimePlanMeta")
    end
    if step.tests and #step.tests > 0 then
      push("         tests · " .. table.concat(step.tests, " ; "), "NvimePlanMeta")
    end
    if step.notes and step.notes ~= "" then
      for _, line in ipairs(vim.split(step.notes, "\n", { plain = true })) do
        push("         notes · " .. line, "NvimePlanMeta")
      end
    end
    local last = #lines - 1
    step_index[step.id or 0] = { first = first, last = last }
    push_blank()
  end

  push_rule()
  push("    <CR> execute step    gx done   gp pending   gB blocked   gT tests", "NvimePlanFooter")
  push("    ]s [s navigate       gA run next pending   gd refine   gr replan", "NvimePlanFooter")
  push("    o open file          c copy intent         ? help      q close", "NvimePlanFooter")
  push_blank()

  return lines, marks, step_index
end

local function configure_window(winid)
  vim.wo[winid].wrap = true
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].cursorline = true
  vim.wo[winid].spell = false
  vim.wo[winid].winblend = 0
  vim.wo[winid].winhighlight =
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted,CursorLine:NvimeCursorLine"
end

local function open_plan_window(bufnr, title)
  local existing = state.panels.plan
  local dim = dimensions()
  local config = {
    relative = "editor",
    width = dim.width,
    height = dim.height,
    row = dim.row,
    col = dim.col,
    style = "minimal",
    border = dim.border,
    title = " " .. title .. " ",
    title_pos = "center",
    footer = " <CR> exec  gx done  ]s/[s nav  gd discuss  gr replan  q close ",
    footer_pos = "center",
    zindex = 54,
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
        vim.api.nvim_buf_set_extmark(bufnr, PLAN_NS, mark.row, col_start, {
          end_col = col_end,
          hl_group = mark.hl,
        })
      end
    end
  end
  set_locked(bufnr, true)

  vim.b[bufnr].nvime_plan_id = plan.id
  vim.b[bufnr].nvime_plan_step_index = step_index

  local winid
  if opts.open ~= false then
    open_backdrop("view")
    winid = open_plan_window(bufnr, "nvime plan · " .. (plan.title or plan.id))
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

-- forward declarations for keymap closures
local install_plan_view_keymaps
local install_picker_keymaps
local refresh_picker
local picker_winid

-- ============================================================================
-- Step operations
-- ============================================================================

local function set_step_status(plan_id, step_id, new_status)
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
  if range == "new" or range == nil then
    line1, line2 = 1, total_lines
  elseif type(range) == "table" then
    line1 = clamp_int(range.line1 or range[1], 1)
    line2 = clamp_int(range.line2 or range[2], line1)
    line1 = math.max(1, math.min(line1 or 1, total_lines))
    line2 = math.max(line1, math.min(line2 or line1, total_lines))
  else
    line1, line2 = 1, total_lines
  end
  vim.api.nvim_win_set_cursor(0, { line1, 0 })
  return true, { bufnr = bufnr, line1 = line1, line2 = line2, path = file }
end

local function plan_context_block(plan, step, char_budget)
  char_budget = char_budget or 480
  local steps = plan.steps or {}
  local total = #steps
  local position = string.format("step %s/%d", tostring(step.id or "?"), total)
  local why = plan.why or ""
  if #why > 220 then
    why = why:sub(1, 217) .. "..."
  end
  local acceptance_lines = {}
  for _, item in ipairs(plan.acceptance or {}) do
    local txt = type(item) == "table" and (item.text or "") or tostring(item)
    if txt ~= "" then
      acceptance_lines[#acceptance_lines + 1] = "  - " .. txt
    end
  end
  local context = {
    "Plan context (informational; do not exceed the selected range):",
    string.format("- Plan: %s — %s", plan.id or "?", plan.title or ""),
    "- Why: " .. why,
    "- " .. position .. ": " .. (step.intent or ""),
  }
  if step.notes and step.notes ~= "" then
    context[#context + 1] = "- Step notes: " .. step.notes
  end
  if #acceptance_lines > 0 then
    context[#context + 1] = "- Plan acceptance:"
    vim.list_extend(context, acceptance_lines)
  end
  local joined = table.concat(context, "\n")
  if #joined > char_budget then
    joined = joined:sub(1, char_budget - 3) .. "..."
  end
  return joined
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

  local cfg = plan_config()
  if cfg.auto_in_progress ~= false then
    set_step_status(plan_id, step.id, "in_progress")
  end

  local context = plan_context_block(plan, step, tonumber(cfg.inject_context_chars) or 480)
  local intent = (step.intent or "") .. "\n\n" .. context

  audit.write({
    event = "plan_step_executing",
    plan_id = plan.id,
    step_id = step.id,
    file = step.file,
  })

  require("nvime.edit").start({
    selection = selection,
    intent = intent,
    line1 = selection.line1,
    line2 = selection.line2,
    range = 2,
    provider = opts.provider,
  })
  return true
end

-- ============================================================================
-- Plan view keymaps
-- ============================================================================

install_plan_view_keymaps = function(bufnr, plan_id, step_index)
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
  "",
  "You MUST NOT modify any source code under the repository root EXCEPT under `.nvime/plans/<plan-id>/`.",
  "nvime synchronizes ONLY files under `.nvime/plans/` back to the user's repository when you exit; anything else you write is silently dropped.",
  "",
  "Tools available:",
  "  - Read, Grep, LS, Glob — to study the codebase.",
  "  - Bash — to run tests, lints, ./scripts/test, git log. Use it to ground claims in real evidence.",
  "  - Web fetch/search — for external context if relevant.",
  "  - Write, Edit, MultiEdit — ONLY for paths under `.nvime/plans/<plan-id>/`.",
  "",
  "Workflow:",
  "  1. Read the user's intent.",
  "  2. Investigate the repo. Be specific: identify actual files, line numbers, dependencies.",
  "  3. Decompose into ORDERED steps. Each step:",
  '     - Targets exactly ONE file and ONE range (existing range, or "new" for a new file).',
  "     - Is small enough to apply through a focused diff review (~5-100 lines).",
  "     - Has CHECKABLE acceptance criteria — prefer shell commands and observable behavior.",
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
  '      "depends_on": [],',
  '      "tests": ["./scripts/test"],',
  '      "status": "pending",',
  '      "notes": "optional context"',
  "    }",
  "  ]",
  "}",
  "",
  "Quality bar:",
  "  - Read enough of the actual code to ground every line/range you cite.",
  "  - If the work has uncertainty, encode the choice in `notes`. Don't punt.",
  "  - Prefer 4-12 small steps over 1-2 huge steps.",
  "  - If the codebase already has a tracked roadmap (e.g. IMPROVEMENTS.md), cite the relevant section in `why`.",
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
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "nvime://plan/run")
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
    footer = " streaming · <C-c> cancel · q close ",
    footer_pos = "center",
    zindex = 54,
  }
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_win_set_buf(existing.winid, bufnr)
    vim.api.nvim_win_set_config(existing.winid, config)
    configure_window(existing.winid)
    return existing.winid
  end
  local winid = vim.api.nvim_open_win(bufnr, true, config)
  configure_window(winid)
  state.panels.plan_run.winid = winid
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

local function run_panel_append(text)
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
  open_backdrop("run")
  open_run_window(run_bufnr)

  state.plan.active_run = { provider = provider, intent = intent, started_at = now_ts() }

  audit.write({ event = "plan_author_start", provider = provider, intent = intent })

  local handle
  handle = agents.run({
    provider = provider,
    lane = "plan",
    prompt = prompt,
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
      if result.code ~= 0 then
        run_panel_append("[nvime] plan author failed (code " .. tostring(result.code) .. ")\n")
        return
      end
      if #synced == 0 then
        run_panel_append("[nvime] no plan files were written; the agent may have refused.\n")
        return
      end
      local plan_id = nil
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
      if plan_id and (plan_config().auto_open ~= false) then
        vim.defer_fn(function()
          close_run_window()
          M.open(plan_id)
        end, 250)
      end
      state.plan.active_run = nil
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

local function close_picker()
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
  push("  ▎  PLANS ", "NvimePlanHeading")
  push(string.format("  %d plan(s) in %s", #plans, plans_dir()), "NvimePlanWhy")
  push("  " .. string.rep("─", 76), "NvimePlanRule")
  push("")

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

local function plan_id_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local rows = vim.b[bufnr].nvime_picker_rows or {}
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local entry = rows[row]
  if entry then
    return entry.plan_id
  end
  return nil
end

install_picker_keymaps = function(bufnr)
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", function()
    local id = plan_id_at_cursor()
    if not id then
      return
    end
    close_picker()
    M.open(id)
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: open" }))

  vim.keymap.set("n", "n", function()
    M.prompt_new()
  end, vim.tbl_extend("force", opts, { desc = "nvime plan: new" }))

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
  local config = {
    relative = "editor",
    width = dim.width,
    height = dim.height,
    row = dim.row,
    col = dim.col,
    style = "minimal",
    border = dim.border,
    title = " nvime plans ",
    title_pos = "center",
    footer = " <CR> open  n new  R refine  dd delete  r refresh  q close ",
    footer_pos = "center",
    zindex = 54,
  }
  local existing_winid = picker_winid()
  open_backdrop("picker")
  if existing_winid then
    vim.api.nvim_win_set_buf(existing_winid, bufnr)
    vim.api.nvim_win_set_config(existing_winid, config)
    configure_window(existing_winid)
  else
    local winid = vim.api.nvim_open_win(bufnr, true, config)
    configure_window(winid)
    state.panels.plan_picker = { bufnr = bufnr, winid = winid }
  end
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
  -- floating footer hint above the last line
  vim.api.nvim_buf_set_extmark(bufnr, COMPOSE_NS, math.max(0, #lines - 1), 0, {
    virt_lines_above = true,
    virt_lines = {
      { { string.rep("─", 78), "NvimePlanRule" } },
      {
        { "  ", "" },
        { "<C-s>", "NvimeKey" },
        { " submit  ", "NvimePlanFooter" },
        { "<C-c>", "NvimeKey" },
        { " cancel running  ", "NvimePlanFooter" },
        { "q", "NvimeKey" },
        { " close (draft preserved)  ", "NvimePlanFooter" },
        { "gx", "NvimeKey" },
        { " clear template", "NvimePlanFooter" },
      },
    },
  })
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
    footer = " <C-s> submit · <C-c> cancel · q close · gx clear template ",
    footer_pos = "center",
    zindex = 54,
  }
end

local function close_compose_window()
  local panel = state.panels.plan_compose
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_close, panel.winid, true)
    panel.winid = nil
  end
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

  vim.keymap.set("n", "gx", function()
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
        "gx    reset the buffer to the template",
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
  local bufnr, fresh = compose_buffer()
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

  open_backdrop("compose")
  local existing = state.panels.plan_compose
  local config = compose_window_config(opts.refine_id)
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_win_set_buf(existing.winid, bufnr)
    vim.api.nvim_win_set_config(existing.winid, config)
    configure_window(existing.winid)
  else
    local winid = vim.api.nvim_open_win(bufnr, true, config)
    configure_window(winid)
    state.panels.plan_compose = { bufnr = bufnr, winid = winid, refine_id = opts.refine_id }
  end

  install_compose_keymaps(bufnr, opts.refine_id)
  compose_decorate(bufnr)

  -- Position cursor at the title field on first open
  if fresh then
    pcall(vim.api.nvim_win_set_cursor, 0, { 3, 0 })
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
  local subs = { "new", "compose", "open", "run", "delete", "discuss", "refresh" }
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

return M
