-- nvime.usage
--
-- Token + cost tracking. Aggregates per-session, per-lane, per-day usage
-- emitted by the providers' streamed JSON envelopes:
--
--   Claude  →  result event:
--                .total_cost_usd
--                .usage.input_tokens / output_tokens
--                .usage.cache_creation_input_tokens / cache_read_input_tokens
--                .modelUsage[<model>].costUSD (per-model breakdown)
--
--   Codex   →  turn.completed event:
--                .usage.input_tokens / output_tokens
--                .usage.cached_input_tokens / reasoning_output_tokens
--                (no cost field — we compute from configurable rates)
--
-- Persisted to .nvime/usage.json (or stdpath('state')/nvime/usage.json
-- when there is no git root). Structure:
--   {
--     version = 1,
--     totals = { input=…, output=…, cache_read=…, cache_creation=…, cost_usd=… },
--     by_lane = { review = { …same shape… }, ... },
--     by_day = { ["2026-05-08"] = { …same shape…, runs=N }, ... },
--     last_run = { provider, lane, model, …, ts },
--   }

local git = require("nvime.git")
local state = require("nvime.state")
local fslock = require("nvime.fslock")
local schema = require("nvime.schema")
local ui = require("nvime.ui")

local M = {}

local SCHEMA_VERSION = 1
local DEFAULT_MAX_DAYS = 90

-- Default per-million-token rates in USD. Tweak via state.config.usage.rates.
-- Cache-read prices are typically 10% of input; cache-creation is 1.25x input
-- for Anthropic 5m and 2x for 1h. We store a single cache_creation rate per
-- model for simplicity; users can override in config.
local DEFAULT_RATES = {
  ["claude-opus-4-8"] = { input = 15.0, output = 75.0, cache_read = 1.5, cache_creation = 18.75 },
  ["claude-opus-4-8[1m]"] = { input = 15.0, output = 75.0, cache_read = 1.5, cache_creation = 18.75 },
  ["claude-sonnet-4-6"] = { input = 3.0, output = 15.0, cache_read = 0.3, cache_creation = 3.75 },
  ["claude-haiku-4-5"] = { input = 1.0, output = 5.0, cache_read = 0.1, cache_creation = 1.25 },
  ["claude-haiku-4-5-20251001"] = { input = 1.0, output = 5.0, cache_read = 0.1, cache_creation = 1.25 },
  -- Codex / GPT-5 family. Rates from https://developers.openai.com/api/docs/pricing
  -- OpenAI charges uncached input at full rate; no separate cache-creation premium.
  ["gpt-5.5"] = { input = 5.0, output = 30.0, cache_read = 0.5, cache_creation = 5.0 },
  ["gpt-5.4"] = { input = 2.0, output = 8.0, cache_read = 0.2, cache_creation = 2.0 },
  ["gpt-5.4-mini"] = { input = 0.4, output = 1.6, cache_read = 0.04, cache_creation = 0.4 },
  ["codex-default"] = { input = 5.0, output = 30.0, cache_read = 0.5, cache_creation = 5.0 },
}

local function usage_config()
  return (state.config or {}).usage or {}
end

local function usage_path()
  local cfg = usage_config()
  if cfg.path and cfg.path ~= "" then
    return vim.fn.fnamemodify(cfg.path, ":p")
  end
  local root = git.root((vim.uv or vim.loop).cwd())
  if root then
    return root .. "/.nvime/usage.json"
  end
  return vim.fn.stdpath("state") .. "/nvime/usage.json"
end

local function ensure_dir(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
end

-- Memoized merged-rates table keyed by the user config's identity. The
-- inputs (DEFAULT_RATES + state.config.usage.rates) only change when the
-- user re-runs setup() or edits config; recomputing per call is wasted.
local cached_rates = nil
local cached_rates_signature = nil
local cached_sorted_keys = nil

local function merged_rates()
  local cfg_rates = usage_config().rates or {}
  local sig = vim.inspect(cfg_rates)
  if cached_rates and cached_rates_signature == sig then
    return cached_rates, cached_sorted_keys
  end
  cached_rates = vim.tbl_extend("force", {}, DEFAULT_RATES, cfg_rates)
  cached_sorted_keys = {}
  for k, _ in pairs(cached_rates) do
    cached_sorted_keys[#cached_sorted_keys + 1] = k
  end
  -- Longest first so prefixes don't shadow more-specific keys (e.g.
  -- "claude-opus-4-8[1m]" should win over "claude-opus-4-8" when both
  -- match a future model id like "claude-opus-4-8[1m]-20260101").
  table.sort(cached_sorted_keys, function(a, b)
    return #a > #b
  end)
  cached_rates_signature = sig
  return cached_rates, cached_sorted_keys
end

local function rate_for(model)
  local rates, sorted = merged_rates()
  if model and rates[model] then
    return rates[model]
  end
  if type(model) == "string" then
    for _, key in ipairs(sorted) do
      if model:sub(1, #key) == key then
        return rates[key]
      end
    end
  end
  return rates["codex-default"] or DEFAULT_RATES["codex-default"]
end

local function blank_bucket()
  return {
    input = 0,
    output = 0,
    cache_read = 0,
    cache_creation = 0,
    reasoning = 0,
    cost_usd = 0,
    runs = 0,
  }
end

local function blank_ledger()
  return {
    version = SCHEMA_VERSION,
    totals = blank_bucket(),
    -- vim.empty_dict() so a fresh round-trip through vim.json.encode
    -- emits {} (a JSON object) rather than [] (an array).
    by_lane = vim.empty_dict(),
    by_day = vim.empty_dict(),
  }
end

local function read_ledger_from_disk()
  local path = usage_path()
  if vim.fn.filereadable(path) ~= 1 then
    return blank_ledger()
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or not raw or #raw == 0 then
    return blank_ledger()
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    return blank_ledger()
  end
  decoded.version = (schema.reconcile(decoded, SCHEMA_VERSION, "usage"))
  decoded.totals = decoded.totals or blank_bucket()
  decoded.by_lane = decoded.by_lane or vim.empty_dict()
  decoded.by_day = decoded.by_day or vim.empty_dict()
  return decoded
end

-- In-memory ledger cache. Loaded once on first access, mutated in place
-- on every record(), flushed on a debounced timer (or on VimLeavePre via
-- M.flush). Removes ~30 ms of sync I/O from every agent_exit.
local cached_ledger = nil
local cached_ledger_path = nil
local save_pending = false
local SAVE_DEBOUNCE_MS = 500

local function ensure_ledger()
  local path = usage_path()
  if cached_ledger and cached_ledger_path == path then
    return cached_ledger
  end
  cached_ledger = read_ledger_from_disk()
  cached_ledger_path = path
  return cached_ledger
end

local function load_ledger()
  return ensure_ledger()
end

local function trim_days(ledger)
  local cap = tonumber(usage_config().max_days) or DEFAULT_MAX_DAYS
  if cap <= 0 then
    return
  end
  local days = {}
  for k, _ in pairs(ledger.by_day) do
    days[#days + 1] = k
  end
  if #days <= cap then
    return
  end
  table.sort(days) -- ascending; oldest first
  for i = 1, #days - cap do
    ledger.by_day[days[i]] = nil
  end
end

local function save_ledger(ledger)
  local path = usage_path()
  ensure_dir(path)
  -- Never downgrade a ledger written by a newer nvime (see nvime.schema).
  if (tonumber(ledger.version) or SCHEMA_VERSION) > SCHEMA_VERSION then
    return false, "schema too new"
  end
  local ok, encoded = pcall(vim.json.encode, ledger)
  if not ok then
    return false, encoded
  end
  -- Atomic, lock-serialized full-file rewrite: a reader never sees a partial
  -- file and a second writer cannot clobber this one mid-rewrite. On lock
  -- contention with_lock returns nil, "locked"; the debounced flusher simply
  -- retries on the next schedule_save (and VimLeavePre flushes a final time).
  return fslock.with_lock(path, function()
    return fslock.atomic_write(path, encoded .. "\n")
  end)
end

local function flush_now()
  save_pending = false
  if cached_ledger then
    save_ledger(cached_ledger)
  end
end

local function schedule_save()
  if save_pending then
    return
  end
  save_pending = true
  vim.defer_fn(flush_now, SAVE_DEBOUNCE_MS)
end

local function bucket_add(bucket, sample)
  bucket.input = (bucket.input or 0) + (sample.input or 0)
  bucket.output = (bucket.output or 0) + (sample.output or 0)
  bucket.cache_read = (bucket.cache_read or 0) + (sample.cache_read or 0)
  bucket.cache_creation = (bucket.cache_creation or 0) + (sample.cache_creation or 0)
  bucket.reasoning = (bucket.reasoning or 0) + (sample.reasoning or 0)
  bucket.cost_usd = (bucket.cost_usd or 0) + (sample.cost_usd or 0)
  bucket.runs = (bucket.runs or 0) + 1
end

local function compute_cost(sample, model)
  if sample.cost_usd and sample.cost_usd > 0 then
    return sample.cost_usd
  end
  local rate = rate_for(model)
  local cost = ((sample.input or 0) * rate.input)
    + ((sample.output or 0) * rate.output)
    + ((sample.cache_read or 0) * rate.cache_read)
    + ((sample.cache_creation or 0) * rate.cache_creation)
    + ((sample.reasoning or 0) * rate.output) -- reasoning tokens are billed as output
  return cost / 1000000.0
end

-- Parse a Claude streamed JSON line decoded into `decoded`. Returns a
-- normalized usage sample (or nil if no usage).
function M.parse_claude(decoded)
  if type(decoded) ~= "table" then
    return nil
  end
  if decoded.type ~= "result" then
    return nil
  end
  local usage = decoded.usage or {}
  local sample = {
    input = tonumber(usage.input_tokens) or 0,
    output = tonumber(usage.output_tokens) or 0,
    cache_read = tonumber(usage.cache_read_input_tokens) or 0,
    cache_creation = tonumber(usage.cache_creation_input_tokens) or 0,
    reasoning = 0,
    cost_usd = tonumber(decoded.total_cost_usd) or 0,
  }
  -- Prefer the highest-cost model in modelUsage (Claude bundles small
  -- auxiliary haiku calls for tool summaries — the user-facing model is
  -- the one driving cost, which is also the one we want to display).
  local model
  if type(decoded.modelUsage) == "table" then
    local best_cost = -1
    for name, info in pairs(decoded.modelUsage) do
      local cost = tonumber(info.costUSD) or 0
      if cost > best_cost then
        best_cost = cost
        model = name
      end
    end
  end
  sample.model = model
  return sample
end

-- Parse a Codex streamed JSON line.
function M.parse_codex(decoded)
  if type(decoded) ~= "table" then
    return nil
  end
  if decoded.type ~= "turn.completed" then
    return nil
  end
  local usage = decoded.usage or {}
  local total_input = tonumber(usage.input_tokens) or 0
  local cached = tonumber(usage.cached_input_tokens) or 0
  return {
    input = total_input - cached,
    output = tonumber(usage.output_tokens) or 0,
    cache_read = cached,
    cache_creation = 0,
    reasoning = tonumber(usage.reasoning_output_tokens) or 0,
    cost_usd = 0,
    model = "codex-default",
  }
end

local function today()
  return os.date("!%Y-%m-%d")
end

-- Budget warnings are advisory and fire at most once per key per nvim session
-- (kept in memory, NOT persisted, so a new session re-reminds when a budget is
-- still over). Daily keys include the date so each new day re-arms.
local budget_warned = {}

local function notify_budget(message)
  vim.schedule(function()
    vim.notify("nvime usage budget: " .. message, vim.log.levels.WARN)
  end)
end

local function check_budgets(ledger, lane, day)
  local budgets = usage_config().budgets or {}
  local function over(key, spent, limit, label)
    limit = tonumber(limit)
    if not limit or limit <= 0 or (spent or 0) < limit then
      return
    end
    if budget_warned[key] then
      return
    end
    budget_warned[key] = true
    notify_budget(string.format("%s spend $%.4f crossed budget $%.4f", label, spent or 0, limit))
  end
  over("daily:" .. day, (ledger.by_day[day] or {}).cost_usd, budgets.daily_usd, "today's")
  over("total", (ledger.totals or {}).cost_usd, budgets.total_usd, "lifetime")
  if type(budgets.lane_usd) == "table" then
    over("lane:" .. lane, (ledger.by_lane[lane] or {}).cost_usd, budgets.lane_usd[lane], "lane '" .. lane .. "'")
  end
end

function M.record(opts)
  if state.disabled then
    return nil
  end
  if usage_config().enabled == false then
    return nil
  end
  opts = opts or {}
  local sample = opts.sample
  if not sample or type(sample) ~= "table" then
    return nil
  end
  sample.cost_usd = compute_cost(sample, sample.model)

  local ledger = ensure_ledger()
  bucket_add(ledger.totals, sample)
  local lane = opts.lane or "unknown"
  ledger.by_lane[lane] = ledger.by_lane[lane] or blank_bucket()
  bucket_add(ledger.by_lane[lane], sample)
  local day = today()
  ledger.by_day[day] = ledger.by_day[day] or blank_bucket()
  bucket_add(ledger.by_day[day], sample)

  ledger.last_run = {
    ts = os.time(),
    iso_ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    provider = opts.provider,
    lane = lane,
    model = sample.model,
    sample = sample,
  }
  check_budgets(ledger, lane, day)
  trim_days(ledger)
  schedule_save()
  return ledger.last_run
end

-- Test/diagnostic hook: clear the per-session budget-warning latches.
function M._reset_budget_warnings()
  budget_warned = {}
end

function M.read()
  return load_ledger()
end

function M.path()
  return usage_path()
end

function M.reset()
  cached_ledger = blank_ledger()
  cached_ledger_path = usage_path()
  ensure_dir(cached_ledger_path)
  flush_now()
end

function M.flush()
  flush_now()
end

local function fmt_usd(v)
  return string.format("$%.4f", v or 0)
end

local function fmt_tokens(n)
  n = n or 0
  if n >= 1000000 then
    return string.format("%.2fM", n / 1000000)
  end
  if n >= 1000 then
    return string.format("%.1fk", n / 1000)
  end
  return tostring(n)
end

function M.statusline_label()
  local ledger = load_ledger()
  local today_bucket = ledger.by_day[today()] or blank_bucket()
  local total_cost = ledger.totals.cost_usd or 0
  return string.format("%s today / %s total", fmt_usd(today_bucket.cost_usd or 0), fmt_usd(total_cost))
end

function M.summary_text()
  local ledger = load_ledger()
  local lines = { "nvime usage", string.rep("─", 40) }
  local totals = ledger.totals
  lines[#lines + 1] = string.format(
    "totals: in %s · out %s · cache(r/c) %s/%s · cost %s · runs %d",
    fmt_tokens(totals.input),
    fmt_tokens(totals.output),
    fmt_tokens(totals.cache_read),
    fmt_tokens(totals.cache_creation),
    fmt_usd(totals.cost_usd),
    totals.runs or 0
  )
  lines[#lines + 1] = ""
  lines[#lines + 1] = "by lane:"
  local lanes = {}
  for name, _ in pairs(ledger.by_lane) do
    lanes[#lanes + 1] = name
  end
  table.sort(lanes)
  for _, lane in ipairs(lanes) do
    local b = ledger.by_lane[lane]
    lines[#lines + 1] = string.format(
      "  %-10s in %s · out %s · cost %s (%d runs)",
      lane,
      fmt_tokens(b.input),
      fmt_tokens(b.output),
      fmt_usd(b.cost_usd),
      b.runs or 0
    )
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "recent days:"
  local days = {}
  for k, _ in pairs(ledger.by_day) do
    days[#days + 1] = k
  end
  table.sort(days, function(a, b)
    return a > b
  end)
  for i = 1, math.min(7, #days) do
    local key = days[i]
    local b = ledger.by_day[key]
    lines[#lines + 1] = string.format(
      "  %s in %s · out %s · cost %s (%d runs)",
      key,
      fmt_tokens(b.input),
      fmt_tokens(b.output),
      fmt_usd(b.cost_usd),
      b.runs or 0
    )
  end
  if ledger.last_run then
    local r = ledger.last_run
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format(
      "last: %s · %s · %s · %s · %s",
      r.iso_ts or "",
      r.provider or "?",
      r.lane or "?",
      r.model or "?",
      fmt_usd((r.sample or {}).cost_usd or 0)
    )
  end
  return table.concat(lines, "\n")
end

-- ---------------------------------------------------------------------------
-- dashboard
--
-- A rendered token + cost dashboard (replacing the old plain-text dump): a
-- runway / burn-rate hero, a daily-cost column plot, per-lane cost bars, and a
-- token / efficiency + stats footer. Built as plain `lines` plus a list of
-- byte-range extmark `marks` (the digest.lua contract) so every block glyph is
-- colored through the shared Nvime* palette. Data is re-read on every open, so
-- the panel always reflects the live ledger; r/t/]/[ rebuild in place.
-- ---------------------------------------------------------------------------

local DASH_NS = vim.api.nvim_create_namespace("nvime.usage.dashboard")
local BACKDROP_NS = vim.api.nvim_create_namespace("nvime.usage.backdrop")

local panel_state = { winid = nil, bufnr = nil, backdrop_winid = nil, backdrop_bufnr = nil }

-- View toggles. Module-lived so r/t/] keep the user's choice across rebuilds.
local view = { metric = "cost", window = 14 }
local WINDOWS = { 7, 14, 30, 0 } -- 0 = max (full span, capped at 90 days)

local RAMP = { "▁", "▂", "▃", "▄", "▅", "▆", "▇" } -- 1/8-block ramp (eighths 1..7)
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
-- day-number 0 == 1970-01-01 == Thursday
local WEEKDAYS = { "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" }

-- Timezone-free Gregorian <-> day-number (days since 1970-01-01) conversion
-- (Howard Hinnant's algorithm). The recorder keys by_day in UTC, so the plot's
-- calendar math and date labels must be UTC too — doing it through os.time
-- (which assumes local time) would skew day boundaries near midnight.
local function days_from_civil(y, m, d)
  y = (m <= 2) and (y - 1) or y
  local era = math.floor((y >= 0 and y or (y - 399)) / 400)
  local yoe = y - era * 400
  local doy = math.floor((153 * ((m > 2) and (m - 3) or (m + 9)) + 2) / 5) + d - 1
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
  return era * 146097 + doe - 719468
end

local function civil_from_days(z)
  z = z + 719468
  local era = math.floor((z >= 0 and z or (z - 146096)) / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460) + math.floor(doe / 36524) - math.floor(doe / 146096)) / 365)
  local y = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp = math.floor((5 * doy + 2) / 153)
  local d = doy - math.floor((153 * mp + 2) / 5) + 1
  local m = (mp < 10) and (mp + 3) or (mp - 9)
  y = (m <= 2) and (y + 1) or y
  return y, m, d
end

local function key_to_daynum(key)
  local y, m, d = tostring(key):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
  if not y then
    return nil
  end
  return days_from_civil(tonumber(y), tonumber(m), tonumber(d))
end

local function fmt_date_long(n) -- "Wed Jul 01"
  local _, m, d = civil_from_days(n)
  return string.format("%s %s %02d", WEEKDAYS[(n % 7) + 1], MONTHS[m], d)
end

local function fmt_date_short(n) -- "Jun 09"
  local _, m, d = civil_from_days(n)
  return string.format("%s %02d", MONTHS[m], d)
end

local function fmt_dd(n) -- "09"
  local _, _, d = civil_from_days(n)
  return string.format("%02d", d)
end

local function tokens_of(b)
  b = b or {}
  return (b.input or 0) + (b.output or 0) + (b.cache_read or 0) + (b.cache_creation or 0) + (b.reasoning or 0)
end

local function fmt_money(v)
  return string.format("$%.2f", v or 0)
end

local function fmt_axis_cost(v)
  v = v or 0
  if v >= 10 then
    return string.format("$%.0f", v)
  elseif v >= 1 then
    return string.format("$%.1f", v)
  end
  return string.format("$%.2f", v)
end

-- ---- line/mark builders ---------------------------------------------------
-- A "segment" is { text, hl? }. push_line concatenates a list of segments into
-- one buffer line and emits a byte-range mark for every segment that carries a
-- highlight — so column math is automatic and always byte-correct even though
-- the glyphs are multi-byte UTF-8.
local function disp(s)
  return vim.fn.strdisplaywidth(s or "")
end

local function push_line(lines, marks, segs)
  local row = #lines
  local parts = {}
  local col = 0
  for _, seg in ipairs(segs) do
    local s = seg[1] or ""
    if seg[2] and #s > 0 then
      marks[#marks + 1] = { row = row, col = col, end_col = col + #s, hl = seg[2] }
    end
    parts[#parts + 1] = s
    col = col + #s
  end
  lines[row + 1] = table.concat(parts)
end

local function segs_disp(segs)
  local w = 0
  for _, seg in ipairs(segs) do
    w = w + disp(seg[1])
  end
  return w
end

-- A left group and a right group separated by enough padding to right-align
-- the right group at display width `width`.
local function lr(left, right, width)
  local gap = math.max(1, width - segs_disp(left) - segs_disp(right))
  local out = {}
  vim.list_extend(out, left)
  out[#out + 1] = { string.rep(" ", gap) }
  vim.list_extend(out, right)
  return out
end

local function pad_right(text, w)
  return tostring(text) .. string.rep(" ", math.max(0, w - disp(text)))
end

local function rjust(text, w)
  return string.rep(" ", math.max(0, w - disp(text))) .. tostring(text)
end

-- Solid fill + empty track, returned as two segments.
local function bar_segs(fill_n, total, fill_hl, track_hl)
  fill_n = math.max(0, math.min(total, math.floor(fill_n + 0.5)))
  return {
    { string.rep("█", fill_n), fill_hl },
    { string.rep("░", total - fill_n), track_hl },
  }
end

-- Place pre-built cells at fixed display columns on one line (for the stats
-- grid). cells = { { col = <display>, segs = {...} }, ... }, ascending col.
local function place_cells(lines, marks, cells)
  local segs = {}
  local cur = 0
  for i, cell in ipairs(cells) do
    -- Pad out to the cell's column; if the previous cell already overran it,
    -- still force a single space so adjacent cells never visually fuse.
    local pad = cell.col - cur
    if i > 1 and pad < 1 then
      pad = 1
    end
    if pad > 0 then
      segs[#segs + 1] = { string.rep(" ", pad) }
      cur = cur + pad
    end
    vim.list_extend(segs, cell.segs)
    cur = cur + segs_disp(cell.segs)
  end
  push_line(lines, marks, segs)
end

local function blank(lines, marks)
  push_line(lines, marks, {})
end

local function rule(lines, marks, width)
  push_line(lines, marks, { { "  " }, { string.rep("─", math.max(1, width - 4)), "NvimeRule" } })
end

-- ---- aggregation ----------------------------------------------------------
local function aggregate(ledger)
  local totals = ledger.totals or blank_bucket()
  local agg = {
    totals = totals,
    spent = totals.cost_usd or 0,
    runs = totals.runs or 0,
    total_tokens = tokens_of(totals),
  }

  local lanes = {}
  for name, b in pairs(ledger.by_lane or {}) do
    if (b.cost_usd or 0) > 0 or (b.runs or 0) > 0 then
      lanes[#lanes + 1] = { name = name, cost = b.cost_usd or 0, runs = b.runs or 0 }
    end
  end
  table.sort(lanes, function(a, b)
    if a.cost == b.cost then
      return a.name < b.name
    end
    return a.cost > b.cost
  end)
  agg.lanes = lanes

  local today_n = key_to_daynum(today()) or 0
  agg.today_n = today_n
  local by_n = {}
  local active, first_n = 0, today_n
  -- Busiest = the highest-cost active day, earliest-wins on ties (deterministic
  -- regardless of pairs() order). Left nil until a real active day is seen so a
  -- ledger of all-$0 days never mislabels today as "busiest $0.00".
  local busiest = nil
  for k, b in pairs(ledger.by_day or {}) do
    local n = key_to_daynum(k)
    if n then
      by_n[n] = b
      if (b.cost_usd or 0) > 0 or (b.runs or 0) > 0 then
        active = active + 1
        if n < first_n then
          first_n = n
        end
        local cost = b.cost_usd or 0
        if not busiest or cost > busiest.cost or (cost == busiest.cost and n < busiest.n) then
          busiest = { n = n, cost = cost }
        end
      end
    end
  end
  agg.active = active
  agg.first_n = first_n
  agg.span = math.max(1, today_n - first_n + 1)
  agg.busiest = busiest or { n = today_n, cost = 0 }
  agg.today_cost = (by_n[today_n] or {}).cost_usd or 0

  -- Burn pace over the last 7 calendar days (idle days count as $0). With less
  -- than a week of history, average over active days instead and say so.
  local window_cost, window_tok = 0, 0
  for n = today_n - 6, today_n do
    local b = by_n[n]
    if b then
      window_cost = window_cost + (b.cost_usd or 0)
      window_tok = window_tok + tokens_of(b)
    end
  end
  if agg.span >= 7 then
    agg.pace_usd = window_cost / 7
    agg.pace_tok = window_tok / 7
    agg.pace_label = "7-day pace"
  else
    local denom = math.max(1, active)
    agg.pace_usd = agg.spent / denom
    agg.pace_tok = agg.total_tokens / denom
    agg.pace_label = denom .. "-day pace"
  end

  -- Plot columns: a contiguous calendar range so idle days read as gaps.
  local win = view.window
  local start_n = (win == 0) and first_n or (today_n - (win - 1))
  if start_n > today_n then
    start_n = today_n
  end
  if today_n - start_n + 1 > 90 then
    start_n = today_n - 89
  end
  local cols = {}
  for n = start_n, today_n do
    local b = by_n[n]
    local value = b and (view.metric == "cost" and (b.cost_usd or 0) or tokens_of(b)) or 0
    cols[#cols + 1] = { n = n, value = value }
  end
  agg.plot_cols = cols
  return agg
end

-- ---- sections -------------------------------------------------------------
local function burn_row(lines, marks, agg, W, proj_segs)
  local left = {
    { "      " },
    { "burn  ", "NvimeMuted" },
    { fmt_money(agg.pace_usd), "NvimeAgent" },
    { " /day", "NvimeFaint" },
    { "  ·  ", "NvimeFaint" },
    { fmt_tokens(agg.pace_tok) .. " tok", "NvimeNormal" },
    { " /day", "NvimeFaint" },
  }
  push_line(lines, marks, lr(left, proj_segs, W))
end

local function render_runway(lines, marks, agg, W)
  local budgets = usage_config().budgets or {}
  local total_usd = tonumber(budgets.total_usd)
  local daily_usd = tonumber(budgets.daily_usd)
  local proj30 = agg.pace_usd * 30
  local bar_cells = math.max(12, W - 22)

  if total_usd and total_usd > 0 then
    push_line(lines, marks, lr({ { "    " }, { "RUNWAY", "NvimeSubtitle" } }, { { agg.pace_label, "NvimeMuted" } }, W))
    blank(lines, marks)

    local remaining = total_usd - agg.spent
    local frac = math.min(1, math.max(0, agg.spent / total_usd))
    local headline, sev_hl, fill_hl, mid
    if remaining <= 0 then
      headline, sev_hl, fill_hl, frac = "BUDGET EXCEEDED", "NvimeStatusError", "NvimeBudgetFillCrit", 1
      mid = { { "over by ", "NvimeMuted" }, { fmt_money(-remaining), "NvimeStatusError" } }
    elseif agg.pace_usd <= 0 then
      headline, sev_hl = "NO RECENT BURN", "NvimeMuted"
      fill_hl = (frac >= 0.9 and "NvimeBudgetFillCrit")
        or (frac >= 0.7 and "NvimeBudgetFillWarn")
        or "NvimeBudgetFillOk"
      mid = { { "idle — no spend in 7d", "NvimeMuted" } }
    else
      local days_left = math.max(0, math.floor(remaining / agg.pace_usd))
      if days_left > 365 then
        headline, sev_hl, fill_hl = "PLENTY OF RUNWAY", "NvimeStatusSuccess", "NvimeBudgetFillOk"
        mid = { { "1yr+ at this pace", "NvimeMuted" } }
      else
        headline = string.format("~%d DAYS LEFT", days_left)
        sev_hl = (days_left <= 7 and "NvimeStatusError")
          or (days_left <= 21 and "NvimeStatusWarn")
          or "NvimeStatusSuccess"
        fill_hl = (days_left <= 7 and "NvimeBudgetFillCrit")
          or (days_left <= 21 and "NvimeBudgetFillWarn")
          or "NvimeBudgetFillOk"
        mid = { { "runs out  ", "NvimeMuted" }, { fmt_date_long(agg.today_n + days_left), "NvimeRowTitle" } }
      end
    end

    local left = { { "      " }, { headline, sev_hl }, { "    " } }
    vim.list_extend(left, mid)
    local right = {
      { fmt_money(agg.spent), "NvimeRowTitle" },
      { " / ", "NvimeMuted" },
      { fmt_money(total_usd), "NvimeMuted" },
    }
    push_line(lines, marks, lr(left, right, W))

    local bar = { { "      " } }
    vim.list_extend(bar, bar_segs(frac * bar_cells, bar_cells, fill_hl, "NvimePlanProgressTrack"))
    bar[#bar + 1] = { "  " }
    bar[#bar + 1] = { string.format("%d%%", math.floor(frac * 100 + 0.5)), sev_hl }
    push_line(lines, marks, bar)

    local proj_hl = (proj30 > remaining) and "NvimeStatusWarn" or "NvimeRowTitle"
    burn_row(lines, marks, agg, W, { { "projected 30d   ", "NvimeMuted" }, { fmt_money(proj30), proj_hl } })
    return
  end

  -- No total budget: hero becomes BURN RATE.
  push_line(lines, marks, lr({ { "    " }, { "BURN RATE", "NvimeSubtitle" } }, { { agg.pace_label, "NvimeMuted" } }, W))
  blank(lines, marks)
  local pace_left = {
    { "      " },
    { fmt_money(agg.pace_usd), "NvimeStatusRunning" },
    { " / day", "NvimeFaint" },
    { "   ·   ", "NvimeFaint" },
    { fmt_tokens(agg.pace_tok) .. " tok", "NvimeNormal" },
    { " / day", "NvimeFaint" },
  }
  push_line(
    lines,
    marks,
    lr(pace_left, { { "projected 30d  ", "NvimeMuted" }, { "~" .. fmt_money(proj30), "NvimeNormal" } }, W)
  )

  if daily_usd and daily_usd > 0 then
    local frac = math.min(1.5, agg.today_cost / daily_usd)
    local pct = math.floor(frac * 100 + 0.5)
    local fill_hl = (frac >= 1 and "NvimeBudgetFillCrit")
      or (frac >= 0.8 and "NvimeBudgetFillWarn")
      or "NvimeBudgetFillOk"
    local pct_hl = (frac >= 1 and "NvimeStatusError") or (frac >= 0.8 and "NvimeStatusWarn") or "NvimeStatusSuccess"
    local bar = { { "      " } }
    vim.list_extend(bar, bar_segs(math.min(1, frac) * bar_cells, bar_cells, fill_hl, "NvimePlanProgressTrack"))
    bar[#bar + 1] = { "  " }
    bar[#bar + 1] = { fmt_money(agg.today_cost) .. " / " .. fmt_money(daily_usd) .. " today", "NvimeMuted" }
    push_line(lines, marks, bar)
    push_line(lines, marks, {
      { "      " },
      { string.format("%d%%", pct), pct_hl },
      { " of daily budget        set  ", "NvimeFaint" },
      { "usage.budgets.total_usd", "NvimeKey" },
      { "  for a runway", "NvimeFaint" },
    })
  else
    blank(lines, marks)
    push_line(lines, marks, {
      { "      " },
      { "no budget set — add  ", "NvimeFaint" },
      { "usage.budgets.total_usd", "NvimeKey" },
      { "  for a runway estimate", "NvimeFaint" },
    })
  end
end

local function render_plot(lines, marks, agg, W)
  local is_cost = view.metric == "cost"
  local title = is_cost and "DAILY COST" or "DAILY TOKENS"
  local cols = vim.deepcopy(agg.plot_cols or {})

  -- Geometry FIRST: pick column width/gap, then drop the OLDEST columns until
  -- the bars fit the float. Everything below (peak, day count, bar scaling,
  -- axis labels) is then derived over the columns actually drawn — never an
  -- off-screen day that got trimmed away on a narrow terminal.
  local gutter = 6
  local body_w = math.max(10, W - gutter - 2)
  local gw, gap
  local D = #cols
  if D <= 2 then
    gw, gap = 2, 3
  elseif D <= 8 then
    gw, gap = 2, 2
  elseif D <= 24 then
    gw, gap = 1, 2
  elseif D <= 40 then
    gw, gap = 1, 1
  else
    gw, gap = 1, 0
  end
  local function fits(n)
    return n * gw + math.max(0, n - 1) * gap <= body_w
  end
  while D > 1 and not fits(D) do
    table.remove(cols, 1) -- drop the oldest column so the most recent days stay
    D = #cols
  end
  local pitch = gw + gap

  local vmax = 0
  for _, c in ipairs(cols) do
    if c.value > vmax then
      vmax = c.value
    end
  end
  local peak_str = is_cost and fmt_money(vmax) or (fmt_tokens(vmax) .. " tok")
  local annot = {
    { string.format("%d days · peak ", #cols), "NvimeMuted" },
    { peak_str, "NvimeRowMeta" },
  }
  push_line(lines, marks, lr({ { "    " }, { title, "NvimeSubtitle" } }, annot, W))
  blank(lines, marks)

  if vmax <= 0 or #cols == 0 then
    local msg = is_cost and "no billable cost in this window" or "no token usage in this window"
    push_line(lines, marks, { { "     " }, { msg, "NvimeMuted" } })
    return
  end

  local plot_h = 4
  local meta = {}
  for i, c in ipairs(cols) do
    local eighths = (c.value > 0) and math.max(1, math.floor(c.value / vmax * plot_h * 8 + 0.5)) or 0
    local frac = c.value / vmax
    local hl
    if c.value <= 0 then
      hl = nil
    elseif c.value >= vmax then
      hl = "NvimePlotPeak"
    elseif frac >= 2 / 3 then
      hl = "NvimePlotHigh"
    elseif frac >= 1 / 3 then
      hl = "NvimePlotMid"
    else
      hl = "NvimePlotLow"
    end
    meta[i] = { eighths = eighths, hl = hl, full = math.floor(eighths / 8), partial = eighths % 8 }
  end

  local top_label = (view.metric == "cost") and fmt_axis_cost(vmax) or fmt_tokens(vmax)
  for r = 1, plot_h do
    local from_bottom = plot_h - r + 1
    local segs = {}
    if r == 1 then
      segs[#segs + 1] = { rjust(top_label, gutter - 1), "NvimeRowMeta" }
      segs[#segs + 1] = { "┤", "NvimeFaint" }
    else
      segs[#segs + 1] = { string.rep(" ", gutter - 1) }
      segs[#segs + 1] = { "│", "NvimeFaint" }
    end
    for i = 1, D do
      local m = meta[i]
      local glyph = " "
      if m.eighths > 0 then
        if from_bottom <= m.full then
          glyph = "█"
        elseif from_bottom == m.full + 1 and m.partial > 0 then
          glyph = RAMP[m.partial]
        end
      end
      if glyph ~= " " and m.hl then
        segs[#segs + 1] = { string.rep(glyph, gw), m.hl }
      else
        segs[#segs + 1] = { string.rep(glyph, gw) }
      end
      if i < D and gap > 0 then
        segs[#segs + 1] = { string.rep(" ", gap) }
      end
    end
    push_line(lines, marks, segs)
  end

  -- baseline / axis row
  local axis_label = (view.metric == "cost") and "$0" or "0"
  local body_len = D * gw + math.max(0, D - 1) * gap
  push_line(lines, marks, {
    { rjust(axis_label, gutter - 1), "NvimeRowMeta" },
    { "┼", "NvimeFaint" },
    { string.rep("─", body_len), "NvimeFaint" },
  })

  -- x-axis day labels (ASCII → byte offsets == display columns). Size the
  -- buffer to the full content width so the last (today's) label is never
  -- clipped when it would reach just past the bar body.
  local row = #lines
  local cells = {}
  for _ = 1, math.max(gutter + body_len, W) do
    cells[#cells + 1] = " "
  end
  local label_marks = {}
  local label_step = math.max(1, math.ceil(3 / pitch))
  for i = 1, D do
    local is_peak = cols[i].value >= vmax and cols[i].value > 0
    if is_peak or i == 1 or i == D or ((i - 1) % label_step == 0) then
      local label = fmt_dd(cols[i].n)
      local start = gutter + (i - 1) * pitch
      if start + #label <= #cells then
        local clear = true
        for j = start + 1, start + #label do
          if cells[j] ~= " " then
            clear = false
          end
        end
        if clear then
          for j = 1, #label do
            cells[start + j] = label:sub(j, j)
          end
          label_marks[#label_marks + 1] =
            { row = row, col = start, end_col = start + #label, hl = is_peak and "NvimeRowTitle" or "NvimeMuted" }
        end
      end
    end
  end
  lines[row + 1] = table.concat(cells)
  vim.list_extend(marks, label_marks)
end

local function render_lanes(lines, marks, agg, W)
  local lanes = agg.lanes
  if #lanes == 0 then
    return
  end
  push_line(
    lines,
    marks,
    lr(
      { { "    " }, { "COST BY LANE", "NvimeSubtitle" } },
      { { "share of ", "NvimeMuted" }, { fmt_money(agg.spent), "NvimeRowMeta" } },
      W
    )
  )
  blank(lines, marks)

  -- Collapse a long tail into one "other" row so the chart stays calm.
  local rows = {}
  if #lanes > 6 then
    for i = 1, 5 do
      rows[i] = lanes[i]
    end
    local other = { name = string.format("other (%d)", #lanes - 5), cost = 0, runs = 0, faint = true }
    for i = 6, #lanes do
      other.cost = other.cost + lanes[i].cost
      other.runs = other.runs + lanes[i].runs
    end
    rows[#rows + 1] = other
  else
    rows = lanes
  end

  local maxcost = lanes[1].cost
  local lane_budgets = (usage_config().budgets or {}).lane_usd or {}
  local bar_cells = math.max(12, W - 38)
  for i, ln in ipairs(rows) do
    local frac = maxcost > 0 and (ln.cost / maxcost) or 0
    local share = agg.spent > 0 and (ln.cost / agg.spent) or 0
    local label_hl = ln.faint and "NvimeMuted" or (i == 1 and "NvimeAgent" or "NvimeNormal")
    local fill_hl = i == 1 and "NvimeAgent" or "NvimeStatusRunning"

    local segs = { { "     " }, { pad_right(ui.truncate(ln.name, 8), 8), label_hl } }
    vim.list_extend(segs, bar_segs(frac * bar_cells, bar_cells, fill_hl, "NvimePlanProgressTrack"))

    local amount = string.format("%.2f", ln.cost)
    local dollar = "$" .. amount
    segs[#segs + 1] = { "  " .. string.rep(" ", math.max(0, 8 - disp(dollar))) }
    segs[#segs + 1] = { "$", "NvimeFaint" }
    segs[#segs + 1] = { amount, "NvimeRowTitle" }
    segs[#segs + 1] = { "  " }
    segs[#segs + 1] = { rjust(string.format("%d%%", math.floor(share * 100 + 0.5)), 4), "NvimeMuted" }
    segs[#segs + 1] = { " " }
    segs[#segs + 1] = { rjust(tostring(ln.runs) .. "×", 5), "NvimeFaint" }

    local limit = tonumber(lane_budgets[ln.name])
    if limit and limit > 0 and ln.cost >= limit then
      segs[#segs + 1] = { " " }
      segs[#segs + 1] = { " over ", ln.cost > limit * 1.2 and "NvimeBadgeError" or "NvimeBadgeWarn" }
    end
    push_line(lines, marks, segs)
  end
end

local function render_tokens(lines, marks, agg, W)
  local t = agg.totals
  push_line(
    lines,
    marks,
    lr(
      { { "    " }, { "TOKENS & EFFICIENCY", "NvimeSubtitle" } },
      { { fmt_tokens(agg.total_tokens) .. " tok total", "NvimeMuted" } },
      W
    )
  )
  blank(lines, marks)

  local token_segs = {
    { "     " },
    { "in ", "NvimeMuted" },
    { fmt_tokens(t.input), "NvimeNormal" },
    { "    " },
    { "out ", "NvimeMuted" },
    { fmt_tokens(t.output), "NvimeNormal" },
    { "    " },
    { "cache ", "NvimeMuted" },
    { fmt_tokens((t.cache_read or 0) + (t.cache_creation or 0)), "NvimeNormal" },
  }
  if (t.reasoning or 0) > 0 then
    token_segs[#token_segs + 1] = { "    " }
    token_segs[#token_segs + 1] = { "reasoning ", "NvimeMuted" }
    token_segs[#token_segs + 1] = { fmt_tokens(t.reasoning), "NvimeNormal" }
  end
  push_line(lines, marks, token_segs)

  local denom = (t.cache_read or 0) + (t.input or 0)
  local hit = denom > 0 and ((t.cache_read or 0) / denom) or 0
  local cbar = math.max(12, math.min(40, W - 42))
  local hit_hl = hit >= 0.7 and "NvimeStatusSuccess" or "NvimeStatusWarn"
  local left = { { "     " }, { "cache hit  ", "NvimeMuted" } }
  vim.list_extend(left, bar_segs(hit * cbar, cbar, hit_hl, "NvimePlanProgressTrack"))
  left[#left + 1] = { "  " }
  left[#left + 1] = { string.format("%d%%", math.floor(hit * 100 + 0.5)), "NvimeRowTitle" }
  local right
  if (t.input or 0) > 0 then
    right = { { "out/in ", "NvimeMuted" }, { string.format("%.2f×", (t.output or 0) / t.input), "NvimeNormal" } }
  else
    right = { { "out/in  —", "NvimeMuted" } }
  end
  push_line(lines, marks, lr(left, right, W))
end

local function render_stats(lines, marks, agg, ledger, W)
  blank(lines, marks)
  push_line(lines, marks, { { "    " }, { "STATS", "NvimeSubtitle" } })

  local third = math.max(20, math.floor((W - 5) / 3))
  local c1, c2, c3 = 5, 5 + third, 5 + third * 2
  local avg = agg.runs > 0 and (agg.spent / agg.runs) or 0
  local top_lane = (#agg.lanes > 0) and agg.lanes[1].name or "—"

  place_cells(lines, marks, {
    { col = c1, segs = { { "avg/run  ", "NvimeMuted" }, { fmt_money(avg), "NvimeRowDetail" } } },
    {
      col = c2,
      segs = {
        { "busiest  ", "NvimeMuted" },
        { fmt_date_short(agg.busiest.n), "NvimeNormal" },
        { " ", "NvimeMuted" },
        { fmt_money(agg.busiest.cost), "NvimeStatus" },
      },
    },
    {
      col = c3,
      segs = {
        { "active  ", "NvimeMuted" },
        { string.format("%d of %d days", agg.active, agg.span), "NvimeNormal" },
      },
    },
  })

  local last = ledger.last_run
  local last_segs = { { "last  ", "NvimeMuted" } }
  if last and last.ts then
    local lane = last.lane or "?"
    local lane_hl = lane == "review" and "NvimeAgent" or "NvimeNormal"
    last_segs[#last_segs + 1] = { ui.relative_time(last.ts) .. " ago", "NvimeFaint" }
    last_segs[#last_segs + 1] = { " · ", "NvimeFaint" }
    last_segs[#last_segs + 1] = { lane, lane_hl }
  else
    last_segs[#last_segs + 1] = { "—", "NvimeFaint" }
  end

  place_cells(lines, marks, {
    {
      col = c1,
      segs = { { "first  ", "NvimeMuted" }, { fmt_date_short(agg.first_n), "NvimeNormal" } },
    },
    { col = c2, segs = { { "top lane  ", "NvimeMuted" }, { top_lane, "NvimeNormal" } } },
    { col = c3, segs = last_segs },
  })
end

-- ---- empty state ----------------------------------------------------------
local function center(lines, marks, segs, W)
  local width = segs_disp(segs)
  local out = { { string.rep(" ", math.max(0, math.floor((W - width) / 2))) } }
  vim.list_extend(out, segs)
  push_line(lines, marks, out)
end

local function render_empty(W)
  local lines, marks = {}, {}
  blank(lines, marks)
  blank(lines, marks)
  center(lines, marks, { { ui.icon("brand"), "NvimeStatus" } }, W)
  blank(lines, marks)
  center(lines, marks, { { "No usage recorded yet.", "NvimeRowTitle" } }, W)
  blank(lines, marks)
  center(lines, marks, { { "Run a Claude or Codex task through nvime and your", "NvimeMuted" } }, W)
  center(lines, marks, { { "cost, token burn, and runway will appear here.", "NvimeMuted" } }, W)
  blank(lines, marks)
  center(lines, marks, { { string.rep("░", math.min(40, W - 8)), "NvimePlanProgressTrack" } }, W)
  center(lines, marks, { { "waiting for first run", "NvimeFaint" } }, W)
  blank(lines, marks)
  center(lines, marks, {
    { "tip", "NvimeKey" },
    { "   set  ", "NvimeMuted" },
    { "usage.budgets.total_usd", "NvimeKey" },
    { "  for a runway gauge", "NvimeMuted" },
  }, W)
  blank(lines, marks)
  return lines, marks
end

-- ---- assembly -------------------------------------------------------------
local function build_dashboard(ledger, W)
  if (ledger.totals and ledger.totals.runs or 0) == 0 then
    local empty_lines, empty_marks = render_empty(W)
    return empty_lines, empty_marks, true
  end
  local agg = aggregate(ledger)
  local lines, marks = {}, {}
  blank(lines, marks)
  render_runway(lines, marks, agg, W)
  blank(lines, marks)
  rule(lines, marks, W)
  blank(lines, marks)
  render_plot(lines, marks, agg, W)
  blank(lines, marks)
  rule(lines, marks, W)
  blank(lines, marks)
  render_lanes(lines, marks, agg, W)
  blank(lines, marks)
  rule(lines, marks, W)
  blank(lines, marks)
  render_tokens(lines, marks, agg, W)
  render_stats(lines, marks, agg, ledger, W)
  blank(lines, marks)
  return lines, marks, false
end

-- ---- title / footer -------------------------------------------------------
local function title_chunks(ledger)
  local chunks = {
    { " " },
    { ui.icon("brand"), "NvimeTitle" },
    { "  nvime", "NvimeSection" },
    { " · usage ", "NvimeMuted" },
  }
  local last = ledger.last_run
  if last and last.provider then
    local provider_hl = last.provider == "claude" and "NvimeProviderClaude" or "NvimeProviderCodex"
    chunks[#chunks + 1] = { "— ", "NvimeFaint" }
    chunks[#chunks + 1] = { last.provider, provider_hl }
    if last.model and last.model ~= "" then
      local model = tostring(last.model):gsub("^claude%-", ""):gsub("^codex%-", "")
      chunks[#chunks + 1] = { " · " .. model, "NvimeMuted" }
    end
    chunks[#chunks + 1] = { " " }
  end
  return chunks
end

local function footer_chunks(empty)
  local f = {
    { " " },
    { "q", "NvimeKey" },
    { " close   ", "NvimeMuted" },
    { "r", "NvimeKey" },
    { " refresh", "NvimeMuted" },
  }
  if not empty then
    f[#f + 1] = { "   " }
    f[#f + 1] = { "t", "NvimeKey" }
    f[#f + 1] = { " " .. (view.metric == "cost" and "tokens" or "cost"), "NvimeMuted" }
    f[#f + 1] = { "   " }
    f[#f + 1] = { "]", "NvimeKey" }
    f[#f + 1] = { " range", "NvimeMuted" }
  end
  f[#f + 1] = { " " }
  return f
end

-- ---- window plumbing ------------------------------------------------------
local function close_backdrop()
  if panel_state.backdrop_winid and vim.api.nvim_win_is_valid(panel_state.backdrop_winid) then
    pcall(vim.api.nvim_win_close, panel_state.backdrop_winid, true)
  end
  if panel_state.backdrop_bufnr and vim.api.nvim_buf_is_valid(panel_state.backdrop_bufnr) then
    pcall(vim.api.nvim_buf_delete, panel_state.backdrop_bufnr, { force = true })
  end
  panel_state.backdrop_winid = nil
  panel_state.backdrop_bufnr = nil
end

local function open_backdrop()
  local cfg = (state.config or {}).ui or {}
  if cfg.backdrop == false then
    return
  end
  if panel_state.backdrop_winid and vim.api.nvim_win_is_valid(panel_state.backdrop_winid) then
    return
  end
  local height = math.max(1, vim.o.lines - 1)
  local width = math.max(1, vim.o.columns)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  local blanks = {}
  for _ = 1, height do
    blanks[#blanks + 1] = string.rep(" ", width)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, blanks)
  for r = 0, height - 1 do
    vim.api.nvim_buf_set_extmark(bufnr, BACKDROP_NS, r, 0, { end_col = width, hl_group = "NvimeBackdrop" })
  end
  local ok, winid = pcall(vim.api.nvim_open_win, bufnr, false, {
    relative = "editor",
    width = width,
    height = height,
    row = 0,
    col = 0,
    style = "minimal",
    focusable = false,
    zindex = 49,
  })
  if not ok then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    return
  end
  vim.wo[winid].winblend = tonumber(cfg.backdrop) or 60
  vim.wo[winid].winhighlight = "NormalFloat:NvimeBackdrop"
  panel_state.backdrop_bufnr = bufnr
  panel_state.backdrop_winid = winid
end

local function close_panel()
  if panel_state.winid and vim.api.nvim_win_is_valid(panel_state.winid) then
    pcall(vim.api.nvim_win_close, panel_state.winid, true)
  end
  if panel_state.bufnr and vim.api.nvim_buf_is_valid(panel_state.bufnr) then
    pcall(vim.api.nvim_buf_delete, panel_state.bufnr, { force = true })
  end
  panel_state.winid = nil
  panel_state.bufnr = nil
  close_backdrop()
end

local function cycle_window(delta)
  local idx = 2
  for i, w in ipairs(WINDOWS) do
    if w == view.window then
      idx = i
    end
  end
  idx = ((idx - 1 + delta) % #WINDOWS) + 1
  view.window = WINDOWS[idx]
end

function M.open_panel()
  ui.ensure_highlights()
  local ledger = load_ledger()
  local W = math.max(64, math.min(80, vim.o.columns - 8))
  local lines, marks, empty = build_dashboard(ledger, W)

  local bufnr = panel_state.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "nvime-usage"
    panel_state.bufnr = bufnr
  end
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].readonly = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, DASH_NS, 0, -1)
  for _, mark in ipairs(marks) do
    local line = lines[mark.row + 1] or ""
    local s = math.max(0, math.min(mark.col, #line))
    local e = math.max(s, math.min(mark.end_col, #line))
    if e > s then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, DASH_NS, mark.row, s, { end_col = e, hl_group = mark.hl })
    end
  end
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local height = math.max(8, math.min(#lines, vim.o.lines - 4))
  local config = {
    relative = "editor",
    width = W,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2 - 1)),
    col = math.max(0, math.floor((vim.o.columns - W) / 2)),
    style = "minimal",
    border = ((state.config or {}).ui or {}).border or "rounded",
    title = title_chunks(ledger),
    title_pos = "center",
    footer = footer_chunks(empty),
    footer_pos = "center",
    zindex = 50,
  }

  open_backdrop()
  local winid = panel_state.winid
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_set_buf(winid, bufnr)
    vim.api.nvim_win_set_config(winid, config)
  else
    winid = vim.api.nvim_open_win(bufnr, true, config)
    -- Tie the dim backdrop's lifetime to the float: close it however the float
    -- goes away (q/<Esc>, :q, <C-w>c, programmatic close), not just via our own
    -- keymaps. close_backdrop is idempotent, so the q/<Esc> path firing this
    -- too is harmless. r/t/]/[ reuse the window (no close), so no duplicate.
    vim.api.nvim_create_autocmd("WinClosed", {
      pattern = tostring(winid),
      once = true,
      callback = function()
        panel_state.winid = nil
        close_backdrop()
      end,
    })
  end
  panel_state.winid = winid
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].winhighlight =
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted"
  pcall(vim.api.nvim_set_current_win, winid)

  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "q", close_panel, opts)
  vim.keymap.set("n", "<Esc>", close_panel, opts)
  vim.keymap.set("n", "r", M.open_panel, opts)
  if not empty then
    vim.keymap.set("n", "t", function()
      view.metric = (view.metric == "cost") and "tokens" or "cost"
      M.open_panel()
    end, opts)
    vim.keymap.set("n", "]", function()
      cycle_window(1)
      M.open_panel()
    end, opts)
    vim.keymap.set("n", "[", function()
      cycle_window(-1)
      M.open_panel()
    end, opts)
  end
  return bufnr, winid
end

function M.close_panel()
  close_panel()
end

function M.fmt_tokens(n)
  return fmt_tokens(n)
end

function M.fmt_usd(v)
  return fmt_usd(v)
end

function M.run_summary(sample)
  if not sample or type(sample) ~= "table" then
    return nil
  end
  local out = (sample.output or 0) + (sample.reasoning or 0)
  local new = sample.input or 0
  local cached = (sample.cache_read or 0) + (sample.cache_creation or 0)
  if cached > 0 then
    return string.format(
      "↑%s out · ↓%s new · ↓%s cached · %s",
      fmt_tokens(out),
      fmt_tokens(new),
      fmt_tokens(cached),
      fmt_usd(sample.cost_usd)
    )
  end
  return string.format("↑%s out · ↓%s ctx · %s", fmt_tokens(out), fmt_tokens(new), fmt_usd(sample.cost_usd))
end

return M
