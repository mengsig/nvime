local audit = require("nvime.audit")
local state = require("nvime.state")
local ui = require("nvime.ui")

-- Audit summarizer.
--
-- Streams .nvime/audit.jsonl, groups events by (lane, day, file, session),
-- and renders a compact digest in a float. Unlike :NvimeAudit (which opens
-- the raw jsonl), this surface is meant to make the *risky* events legible:
-- block_force_applied, block_conflict, plan_step_rollback, agent_cancelled.

local M = {}

local DIGEST_NS = vim.api.nvim_create_namespace("nvime.digest")
local DIGEST_BACKDROP_NS = vim.api.nvim_create_namespace("nvime.digest.backdrop")
local DEFAULT_WINDOW_DAYS = 7

local function parse_iso_ts(value)
  if type(value) ~= "string" then
    return nil
  end
  local year, month, day, hour, min, sec = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not year then
    return nil
  end
  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })
end

function M.read_events(opts)
  opts = opts or {}
  local path = opts.path or audit.path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines then
    return {}
  end
  local cutoff = nil
  if opts.window_days then
    cutoff = os.time() - opts.window_days * 86400
  elseif opts.since_ts then
    cutoff = opts.since_ts
  end
  local events = {}
  for _, line in ipairs(lines) do
    if line ~= "" then
      local decoded_ok, decoded = pcall(vim.json.decode, line)
      if decoded_ok and type(decoded) == "table" then
        local ts = parse_iso_ts(decoded.ts) or 0
        if not cutoff or ts >= cutoff then
          decoded._ts = ts
          events[#events + 1] = decoded
        end
      end
    end
  end
  return events
end

local function ensure_counts(table_, key)
  table_[key] = table_[key] or 0
  return table_[key]
end

local function relative_time(ts)
  if not ts or ts == 0 then
    return "unknown"
  end
  return ui.relative_time(ts)
end

function M.summarize(events)
  local stats = {
    total = #events,
    by_lane = {},
    by_event = {},
    by_provider = {},
    risky = {},
    sessions = {},
    plans = {},
    files_touched = {},
    earliest_ts = nil,
    latest_ts = nil,
  }

  for _, event in ipairs(events) do
    local kind = event.event or "unknown"
    ensure_counts(stats.by_event, kind)
    stats.by_event[kind] = stats.by_event[kind] + 1

    if event.lane then
      ensure_counts(stats.by_lane, event.lane)
      stats.by_lane[event.lane] = stats.by_lane[event.lane] + 1
    end
    if event.provider then
      ensure_counts(stats.by_provider, event.provider)
      stats.by_provider[event.provider] = stats.by_provider[event.provider] + 1
    end
    if event.plan_id then
      ensure_counts(stats.plans, event.plan_id)
      stats.plans[event.plan_id] = stats.plans[event.plan_id] + 1
    end
    if event.file then
      ensure_counts(stats.files_touched, event.file)
      stats.files_touched[event.file] = stats.files_touched[event.file] + 1
    end
    if
      kind == "block_force_applied"
      or kind == "block_conflict"
      or kind == "plan_step_rollback"
      or kind == "blocked"
    then
      stats.risky[#stats.risky + 1] = event
    end
    if kind == "agent_start" then
      ensure_counts(stats.sessions, event.lane or "unknown")
      stats.sessions[event.lane or "unknown"] = stats.sessions[event.lane or "unknown"] + 1
    end
    if event._ts and event._ts > 0 then
      if not stats.earliest_ts or event._ts < stats.earliest_ts then
        stats.earliest_ts = event._ts
      end
      if not stats.latest_ts or event._ts > stats.latest_ts then
        stats.latest_ts = event._ts
      end
    end
  end

  return stats
end

function M.force_review(events)
  local out = {}
  for _, event in ipairs(events) do
    if event.event == "block_force_applied" then
      out[#out + 1] = event
    end
  end
  return out
end

local function pad_right(text, width)
  text = text or ""
  local visible = vim.fn.strdisplaywidth(text)
  if visible >= width then
    return text
  end
  return text .. string.rep(" ", width - visible)
end

local function sorted_pairs(map)
  local keys = {}
  for k in pairs(map or {}) do
    keys[#keys + 1] = k
  end
  table.sort(keys, function(a, b)
    return (map[a] or 0) > (map[b] or 0)
  end)
  return keys
end

local function render_digest(stats, window_days)
  local lines = {}
  local marks = {}

  local function push(text, hl)
    text = tostring(text or "")
    lines[#lines + 1] = text
    if hl then
      marks[#marks + 1] = { row = #lines - 1, hl = hl, line = true }
    end
  end

  local function rule()
    push("  " .. string.rep("─", 76), "NvimePlanRule")
  end

  push("")
  push("  ▎  AUDIT SUMMARY ", "NvimePlanHeading")
  if window_days then
    push(string.format("  last %d day(s) · %d events", window_days, stats.total or 0), "NvimePlanWhy")
  else
    push(string.format("  all time · %d events", stats.total or 0), "NvimePlanWhy")
  end
  if stats.earliest_ts and stats.latest_ts then
    push(
      string.format("  range: %s → %s", relative_time(stats.earliest_ts), relative_time(stats.latest_ts)),
      "NvimePlanMeta"
    )
  end
  rule()
  push("")

  push("  ▎ AGENT RUNS BY LANE", "NvimePlanHeading")
  if next(stats.by_lane or {}) == nil then
    push("    (no agent_start events recorded)", "NvimePlanWhy")
  else
    for _, lane in ipairs(sorted_pairs(stats.sessions)) do
      push(string.format("    %s  %s", pad_right(lane, 14), tostring(stats.sessions[lane])), "NvimePlanFile")
    end
  end
  push("")

  push("  ▎ PROVIDERS", "NvimePlanHeading")
  if next(stats.by_provider or {}) == nil then
    push("    (none)", "NvimePlanWhy")
  else
    for _, provider in ipairs(sorted_pairs(stats.by_provider)) do
      push(
        string.format("    %s  %s events", pad_right(provider, 14), tostring(stats.by_provider[provider])),
        "NvimePlanFile"
      )
    end
  end
  push("")

  push("  ▎ RISKY EVENTS", "NvimePlanHeading")
  local risky = stats.risky or {}
  if #risky == 0 then
    push("    none — no force-accepts, no diff conflicts, no rollbacks", "NvimePlanStepDone")
  else
    -- Bucket risky events by type for the summary, then list the most
    -- recent N below.
    local by_type = {}
    for _, event in ipairs(risky) do
      ensure_counts(by_type, event.event or "?")
      by_type[event.event] = by_type[event.event] + 1
    end
    for _, kind in ipairs(sorted_pairs(by_type)) do
      local hl = "NvimePlanStepBlocked"
      if kind == "block_conflict" then
        hl = "NvimePlanStepProgress"
      end
      push(string.format("    %s  %d", pad_right(kind, 24), by_type[kind]), hl)
    end
    push("")
    push("    most recent (newest first):", "NvimePlanWhy")
    table.sort(risky, function(a, b)
      return (a._ts or 0) > (b._ts or 0)
    end)
    for index, event in ipairs(risky) do
      if index > 8 then
        break
      end
      local detail
      if event.event == "block_force_applied" then
        detail = string.format(
          "%s:%d-%d  block %s",
          event.file or "?",
          event.start_line or -1,
          event.end_line or -1,
          tostring(event.block_id or "?")
        )
      elseif event.event == "block_conflict" then
        detail = string.format(
          "%s:%d-%d  block %s",
          event.file or "?",
          event.start_line or -1,
          event.end_line or -1,
          tostring(event.block_id or "?")
        )
      elseif event.event == "plan_step_rollback" then
        detail = string.format(
          "plan %s step %s · %s",
          event.plan_id or "?",
          tostring(event.step_id or "?"),
          event.file or "?"
        )
      elseif event.event == "blocked" then
        detail = string.format("%s · %s", event.surface or "?", event.reason or "?")
      else
        detail = vim.inspect(event):sub(1, 80)
      end
      push(
        string.format("      %s · %s · %s", relative_time(event._ts or 0), event.event or "?", detail),
        "NvimePlanMeta"
      )
    end
  end
  push("")

  push("  ▎ FILES MOST TOUCHED", "NvimePlanHeading")
  if next(stats.files_touched or {}) == nil then
    push("    (no file-scoped events)", "NvimePlanWhy")
  else
    local files_sorted = sorted_pairs(stats.files_touched)
    for index, file in ipairs(files_sorted) do
      if index > 10 then
        break
      end
      push(
        string.format("    %s  %d events", pad_right(file, 50), tostring(stats.files_touched[file])),
        "NvimePlanFile"
      )
    end
  end
  push("")

  push("  ▎ PLANS REFERENCED", "NvimePlanHeading")
  if next(stats.plans or {}) == nil then
    push("    (no plan events recorded)", "NvimePlanWhy")
  else
    for _, plan_id in ipairs(sorted_pairs(stats.plans)) do
      push(string.format("    %s  %d events", pad_right(plan_id, 28), tostring(stats.plans[plan_id])), "NvimePlanFile")
    end
  end
  push("")

  rule()
  push("    q close   r refresh   o open audit raw log", "NvimePlanFooter")
  push("")

  return lines, marks
end

local function render_force_review(events)
  local lines = {}
  local marks = {}

  local function push(text, hl)
    text = tostring(text or "")
    lines[#lines + 1] = text
    if hl then
      marks[#marks + 1] = { row = #lines - 1, hl = hl, line = true }
    end
  end

  push("")
  push("  ▎  FORCE-ACCEPT REVIEW ", "NvimePlanHeading")
  push("  These are the diff blocks that bypassed nvime's live-content guard.", "NvimePlanWhy")
  push("  Each one is a place where the file drifted but you applied the patch", "NvimePlanWhy")
  push("  anyway (gA! or :NvimeAccept!). Worth re-reading.", "NvimePlanWhy")
  push("  " .. string.rep("─", 76), "NvimePlanRule")
  push("")
  if #events == 0 then
    push("    none — no force-accepts in the audit log", "NvimePlanStepDone")
  else
    table.sort(events, function(a, b)
      return (a._ts or 0) > (b._ts or 0)
    end)
    for _, event in ipairs(events) do
      push(
        string.format(
          "  ▎ %s  %s:%d-%d  block %s",
          relative_time(event._ts or 0),
          event.file or "?",
          event.start_line or -1,
          event.end_line or -1,
          tostring(event.block_id or "?")
        ),
        "NvimePlanStepBlocked"
      )
    end
  end
  push("")
  push("  " .. string.rep("─", 76), "NvimePlanRule")
  push("    q close   o open the file at cursor", "NvimePlanFooter")
  push("")
  return lines, marks
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

local function open_backdrop()
  local cfg = (state.config or {}).ui or {}
  if cfg.backdrop == false then
    return nil
  end
  local existing = state.panels.digest_backdrop
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    return existing.winid
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  local height = math.max(1, vim.o.lines - 1)
  local width = math.max(1, vim.o.columns)
  local blank = {}
  for _ = 1, height do
    blank[#blank + 1] = string.rep(" ", width)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, blank)
  vim.api.nvim_buf_clear_namespace(bufnr, DIGEST_BACKDROP_NS, 0, -1)
  for row = 0, height - 1 do
    vim.api.nvim_buf_set_extmark(bufnr, DIGEST_BACKDROP_NS, row, 0, {
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
    return nil
  end
  vim.wo[winid].winblend = tonumber(cfg.backdrop) or 60
  vim.wo[winid].winhighlight = "NormalFloat:NvimeBackdrop"
  state.panels.digest_backdrop = { bufnr = bufnr, winid = winid }
  return winid
end

local function close_backdrop()
  local existing = state.panels.digest_backdrop
  if existing and existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    pcall(vim.api.nvim_win_close, existing.winid, true)
  end
  state.panels.digest_backdrop = nil
end

local function close_panel()
  local panel = state.panels.digest
  if panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid) then
    pcall(vim.api.nvim_win_close, panel.winid, true)
  end
  state.panels.digest = nil
  close_backdrop()
end

local function open_panel(title, footer, lines, marks, on_refresh)
  local existing = state.panels.digest
  if existing and existing.bufnr and vim.api.nvim_buf_is_valid(existing.bufnr) then
    -- reuse buffer
  else
    local bufnr = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, bufnr, "nvime://digest")
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "nvime"
    state.panels.digest = { bufnr = bufnr }
    existing = state.panels.digest
  end
  local bufnr = existing.bufnr
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, DIGEST_NS, 0, -1)
  ui.ensure_highlights()
  for _, mark in ipairs(marks) do
    local line = lines[mark.row + 1] or ""
    if mark.line then
      vim.api.nvim_buf_set_extmark(bufnr, DIGEST_NS, mark.row, 0, {
        end_col = #line,
        hl_group = mark.hl,
        hl_eol = true,
      })
    end
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  open_backdrop()
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
    footer = " " .. footer .. " ",
    footer_pos = "center",
    zindex = 54,
    focusable = true,
  }
  local winid
  if existing.winid and vim.api.nvim_win_is_valid(existing.winid) then
    vim.api.nvim_win_set_buf(existing.winid, bufnr)
    vim.api.nvim_win_set_config(existing.winid, config)
    winid = existing.winid
  else
    winid = vim.api.nvim_open_win(bufnr, true, config)
  end
  vim.wo[winid].wrap = false
  vim.wo[winid].number = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].cursorline = true
  vim.wo[winid].winhighlight =
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted,CursorLine:NvimeCursorLine"
  state.panels.digest = { bufnr = bufnr, winid = winid }
  pcall(vim.api.nvim_set_current_win, winid)

  for _, lhs in ipairs({ "q", "<Esc>", "r", "o" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "q", close_panel, vim.tbl_extend("force", opts, { desc = "nvime digest: close" }))
  vim.keymap.set("n", "<Esc>", close_panel, vim.tbl_extend("force", opts, { desc = "nvime digest: close" }))
  if on_refresh then
    vim.keymap.set("n", "r", on_refresh, vim.tbl_extend("force", opts, { desc = "nvime digest: refresh" }))
  end
  vim.keymap.set("n", "o", function()
    close_panel()
    require("nvime.audit").open()
  end, vim.tbl_extend("force", opts, { desc = "nvime digest: open raw audit" }))

  return bufnr, winid
end

function M.show_summary(window_days)
  window_days = window_days or DEFAULT_WINDOW_DAYS
  local events = M.read_events({ window_days = window_days })
  local stats = M.summarize(events)
  local lines, marks = render_digest(stats, window_days)
  return open_panel(
    "nvime audit summary · last " .. tostring(window_days) .. "d",
    "q close · r refresh · o raw audit",
    lines,
    marks,
    function()
      M.show_summary(window_days)
    end
  )
end

function M.show_force_review()
  local events = M.read_events({})
  local forces = M.force_review(events)
  -- Re-attach _ts so the renderer can sort/show times.
  local indexed = {}
  for _, e in ipairs(forces) do
    indexed[#indexed + 1] = e
  end
  local lines, marks = render_force_review(indexed)
  return open_panel("nvime force-accept review", "q close · r refresh · o raw audit", lines, marks, function()
    M.show_force_review()
  end)
end

return M
