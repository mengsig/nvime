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
  -- "claude-opus-4-7[1m]" should win over "claude-opus-4-7" when both
  -- match a future model id like "claude-opus-4-7[1m]-20260101").
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
  decoded.version = SCHEMA_VERSION
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
  local ok, encoded = pcall(vim.json.encode, ledger)
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
  pcall(function()
    fd:close()
  end)
  if not write_ok then
    return false, write_err
  end
  return true
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
  trim_days(ledger)
  schedule_save()
  return ledger.last_run
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

local panel_state = { winid = nil, bufnr = nil }

local function close_panel()
  if panel_state.winid and vim.api.nvim_win_is_valid(panel_state.winid) then
    pcall(vim.api.nvim_win_close, panel_state.winid, true)
  end
  if panel_state.bufnr and vim.api.nvim_buf_is_valid(panel_state.bufnr) then
    pcall(vim.api.nvim_buf_delete, panel_state.bufnr, { force = true })
  end
  panel_state.winid = nil
  panel_state.bufnr = nil
end

function M.open_panel()
  close_panel()
  local lines = vim.split(M.summary_text(), "\n", { plain = true })
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "nvime-usage"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(math.max(width + 4, 60), math.max(60, vim.o.columns - 6))
  local height = math.min(math.max(#lines + 2, 10), math.max(12, vim.o.lines - 6))

  local row = math.max(1, math.floor((vim.o.lines - height) / 2))
  local col = math.max(1, math.floor((vim.o.columns - width) / 2))
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = ((state.config or {}).ui or {}).border or "rounded",
    title = " nvime usage ",
    title_pos = "center",
    footer = " q close · r reset · cwd: " .. (((vim.uv or vim.loop).cwd()) or "") .. " ",
    footer_pos = "center",
    zindex = 50,
  })
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].winhighlight =
    "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle,FloatFooter:NvimeMuted"

  panel_state.winid = winid
  panel_state.bufnr = bufnr

  local function close()
    close_panel()
  end
  vim.keymap.set("n", "q", close, { buffer = bufnr, silent = true, desc = "close nvime usage" })
  vim.keymap.set("n", "<Esc>", close, { buffer = bufnr, silent = true, desc = "close nvime usage" })
  vim.keymap.set("n", "r", function()
    M.reset()
    close()
    M.open_panel()
  end, { buffer = bufnr, silent = true, desc = "reset nvime usage" })
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
