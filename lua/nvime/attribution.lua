local git = require("nvime.git")
local state = require("nvime.state")
local fslock = require("nvime.fslock")
local schema = require("nvime.schema")

-- Per-line attribution ledger.
--
-- Every accepted nvime diff block writes one entry to .nvime/attribution.json
-- (in the current git root, or stdpath("state")/nvime/attribution.json when
-- there is no git root). An entry stores the rationale, critic verdict, plan
-- linkage, and a content anchor so the entry can still be located after later
-- edits shift line numbers.
--
-- Lookup matches by anchor content rather than by line number: given a (file,
-- line) we walk entries for that file, locate each entry's anchor inside the
-- live buffer (first 1-3 lines + line count), and return the entry whose
-- anchor span covers the queried line. Most-recent wins on overlap.

local M = {}

local SCHEMA_VERSION = 1
local DEFAULT_MAX_ENTRIES = 500
local ANCHOR_HEAD_LINES = 3
local ANCHOR_TAIL_LINES = 1
local OVERLAY_NS = vim.api.nvim_create_namespace("nvime.attribution.overlay")

local function attribution_path()
  local cfg = (state.config or {}).attribution or {}
  if cfg.path and cfg.path ~= "" then
    return vim.fn.fnamemodify(cfg.path, ":p")
  end
  local root = git.root()
  if root then
    return root .. "/.nvime/attribution.json"
  end
  return vim.fn.stdpath("state") .. "/nvime/attribution.json"
end

local function max_entries()
  local cfg = (state.config or {}).attribution or {}
  return tonumber(cfg.max) or DEFAULT_MAX_ENTRIES
end

local function ensure_dir(path)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
end

local function read_ledger()
  local path = attribution_path()
  if vim.fn.filereadable(path) ~= 1 then
    return { version = SCHEMA_VERSION, entries = {} }
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or not raw or #raw == 0 then
    return { version = SCHEMA_VERSION, entries = {} }
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not decoded_ok or type(decoded) ~= "table" or type(decoded.entries) ~= "table" then
    return { version = SCHEMA_VERSION, entries = {} }
  end
  decoded.version = (schema.reconcile(decoded, SCHEMA_VERSION, "attribution"))
  return decoded
end

local function trim_entries(entries, cap)
  if #entries <= cap then
    return entries
  end
  local trimmed = {}
  local first = #entries - cap + 1
  for i = first, #entries do
    trimmed[#trimmed + 1] = entries[i]
  end
  return trimmed
end

-- Append one new entry to the ledger under a file lock, re-reading the
-- on-disk state INSIDE the lock before merging. Reading-then-writing without
-- the lock loses updates when two Neovim instances record concurrently: each
-- reads the same ledger, appends its own entry, and the second write drops the
-- first entry. Re-reading under the lock makes the append a true read-modify-
-- write. The file itself is replaced atomically (tmp + rename).
local function append_entry(stored)
  local path = attribution_path()
  ensure_dir(path)
  return fslock.with_lock(path, function()
    local ledger = read_ledger()
    -- Never rewrite a ledger written by a newer nvime; that would downgrade
    -- its schema and drop fields. Skip the append instead (entry is lost, file
    -- stays intact) — the rare, safe failure mode.
    if (tonumber(ledger.version) or SCHEMA_VERSION) > SCHEMA_VERSION then
      return false, "schema too new"
    end
    ledger.entries = ledger.entries or {}
    ledger.entries[#ledger.entries + 1] = stored
    ledger.entries = trim_entries(ledger.entries, max_entries())
    local ok, encoded = pcall(vim.json.encode, ledger)
    if not ok then
      return false, encoded
    end
    return fslock.atomic_write(path, encoded .. "\n")
  end)
end

local function build_anchor(lines)
  local anchor = { head = {}, tail = {}, line_count = #(lines or {}) }
  for i = 1, math.min(ANCHOR_HEAD_LINES, #lines) do
    anchor.head[i] = lines[i]
  end
  if #lines > ANCHOR_HEAD_LINES then
    for i = 1, math.min(ANCHOR_TAIL_LINES, #lines - ANCHOR_HEAD_LINES) do
      anchor.tail[i] = lines[#lines - ANCHOR_TAIL_LINES + i]
    end
  end
  return anchor
end

-- Returns the 1-based start line where this entry's anchor matches in the
-- given buffer lines, or nil when it doesn't match. Anchor matches require
-- exact head equality and (when present) exact tail equality at line_count
-- distance.
local function locate_anchor(buf_lines, entry)
  local anchor = entry.anchor or {}
  local head = anchor.head or {}
  local tail = anchor.tail or {}
  local line_count = anchor.line_count or #head
  if #head == 0 then
    return nil
  end
  local total = #buf_lines
  for start = 1, total - #head + 1 do
    local match = true
    for i = 1, #head do
      if buf_lines[start + i - 1] ~= head[i] then
        match = false
        break
      end
    end
    if match and #tail > 0 then
      local tail_start = start + line_count - #tail
      if tail_start < 1 or tail_start + #tail - 1 > total then
        match = false
      else
        for i = 1, #tail do
          if buf_lines[tail_start + i - 1] ~= tail[i] then
            match = false
            break
          end
        end
      end
    end
    if match then
      return start, start + math.max(line_count, #head) - 1
    end
  end
  return nil
end

local function generate_id()
  -- Best-effort unique id; we only need it for cross-references in the
  -- digest, not cryptographic uniqueness.
  return string.format("%d-%d", os.time(), math.random(0, 0xFFFFFF))
end

function M.path()
  return attribution_path()
end

function M.read()
  return read_ledger()
end

function M.record(entry)
  if state.disabled then
    return
  end
  if type(entry) ~= "table" or not entry.file or not entry.lines or #entry.lines == 0 then
    return
  end
  local cfg = (state.config or {}).attribution or {}
  if cfg.enabled == false then
    return
  end
  local stored = {
    id = generate_id(),
    file = entry.file,
    line1 = entry.line1,
    line2 = entry.line2,
    anchor = build_anchor(entry.lines),
    rationale = entry.rationale,
    user_rationale = entry.user_rationale,
    verdict = entry.verdict,
    -- Compact snapshot of the pre-accept verify gate (parse status + per-check
    -- finding counts + whether the gate was force-bypassed). Absent when verify
    -- was disabled/unavailable, so a missing field reads as "n/a", never "ok".
    verify = entry.verify,
    provider = entry.provider,
    plan_id = entry.plan_id,
    step_id = entry.step_id,
    forced = entry.forced == true,
    diff_session_id = entry.diff_session_id,
    ts = entry.ts or os.time(),
    iso_ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  append_entry(stored)
  return stored
end

-- Returns a list of entries matching (file, line) in most-recent-first order.
-- Anchor matching is exact; an entry is included when the cursor line is
-- inside the anchor's matched span in the live buffer.
function M.for_line(file, lineno, buf_lines)
  if not file then
    return {}
  end
  local ledger = read_ledger()
  local matches = {}
  for _, entry in ipairs(ledger.entries or {}) do
    if entry.file == file then
      local first, last = locate_anchor(buf_lines or {}, entry)
      if first and lineno >= first and lineno <= last then
        matches[#matches + 1] = vim.tbl_extend("keep", { match_line1 = first, match_line2 = last }, entry)
      end
    end
  end
  table.sort(matches, function(a, b)
    return (a.ts or 0) > (b.ts or 0)
  end)
  return matches
end

function M.for_file(file)
  local ledger = read_ledger()
  local out = {}
  for _, entry in ipairs(ledger.entries or {}) do
    if entry.file == file then
      out[#out + 1] = entry
    end
  end
  table.sort(out, function(a, b)
    return (a.ts or 0) > (b.ts or 0)
  end)
  return out
end

-- One-line summary of the persisted verify gate snapshot, or nil when none
-- was recorded (verify disabled/unavailable at accept time). Never fabricates
-- a clean result from absence.
local function verify_summary(v)
  if type(v) ~= "table" then
    return nil
  end
  local parts = { tostring(v.status or "?") }
  if v.parse_ok == false then
    parts[#parts + 1] = "parse ERROR"
  elseif v.parse_ok == true then
    parts[#parts + 1] = "parse ok"
  end
  local checks = {}
  for name, count in pairs(v.checks or {}) do
    if (tonumber(count) or 0) > 0 then
      checks[#checks + 1] = string.format("%s %d", name, count)
    end
  end
  table.sort(checks)
  if #checks > 0 then
    parts[#parts + 1] = table.concat(checks, ", ")
  end
  local text = table.concat(parts, " · ")
  if v.forced then
    text = text .. " (forced past gate)"
  end
  return text
end

M._verify_summary = verify_summary

local function format_entry(entry)
  local lines = {}
  local id = entry.plan_id and (entry.plan_id .. " · step " .. tostring(entry.step_id or "?")) or "edit"
  local forced = entry.forced and " · FORCED" or ""
  lines[#lines + 1] = string.format("[%s · %s]%s", id, entry.provider or "?", forced)
  if entry.rationale and entry.rationale ~= "" then
    lines[#lines + 1] = "rationale: " .. entry.rationale
  end
  if entry.user_rationale and entry.user_rationale ~= "" then
    lines[#lines + 1] = "user: " .. entry.user_rationale
  end
  if type(entry.verdict) == "table" and entry.verdict.decision then
    lines[#lines + 1] = string.format("critic %s: %s", entry.verdict.decision, entry.verdict.justification or "")
  end
  local vsum = verify_summary(entry.verify)
  if vsum then
    lines[#lines + 1] = "verify: " .. vsum
  end
  lines[#lines + 1] = "ts: " .. (entry.iso_ts or os.date("!%Y-%m-%dT%H:%M:%SZ", entry.ts or 0))
  return lines
end

local function close_blame_popup()
  local popup = vim.g.nvime_blame_popup
  if not popup then
    return
  end
  vim.g.nvime_blame_popup = nil
  if popup.winid and vim.api.nvim_win_is_valid(popup.winid) then
    pcall(vim.api.nvim_win_close, popup.winid, true)
  end
  if popup.bufnr and vim.api.nvim_buf_is_valid(popup.bufnr) then
    pcall(vim.api.nvim_buf_delete, popup.bufnr, { force = true })
  end
end

local function open_blame_popup(lines, opts)
  close_blame_popup()
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "nvime-blame"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].readonly = true

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.min(math.max(width + 2, 32), math.max(40, vim.o.columns - 4))
  local height = math.min(#lines, math.max(6, vim.o.lines - 6))

  local winid = vim.api.nvim_open_win(bufnr, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = ((state.config or {}).ui or {}).border or "rounded",
    title = " " .. (opts and opts.title or "nvime attribution") .. " ",
    title_pos = "left",
    zindex = 60,
  })
  vim.wo[winid].wrap = false
  vim.wo[winid].cursorline = false
  vim.wo[winid].winhighlight = "NormalFloat:NvimeNormal,FloatBorder:NvimeBorder,FloatTitle:NvimeTitle"

  vim.g.nvime_blame_popup = { winid = winid, bufnr = bufnr }

  local group = vim.api.nvim_create_augroup("NvimeBlamePopup", { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "InsertEnter", "BufLeave", "WinLeave" }, {
    group = group,
    once = true,
    callback = close_blame_popup,
  })
  vim.keymap.set("n", "q", close_blame_popup, { buffer = bufnr, silent = true, desc = "close nvime blame" })
  vim.keymap.set("n", "<Esc>", close_blame_popup, { buffer = bufnr, silent = true, desc = "close nvime blame" })

  return bufnr, winid
end

local function build_blame_lines(rel, lineno, matches)
  local lines = { string.format("%s:%d", rel, lineno), string.rep("─", 32) }
  for index, entry in ipairs(matches) do
    if index > 1 then
      lines[#lines + 1] = ""
    end
    local span = string.format("lines %d-%d", entry.match_line1, entry.match_line2)
    lines[#lines + 1] = span
    for _, line in ipairs(format_entry(entry)) do
      lines[#lines + 1] = "  " .. line
    end
    if entry.diff_session_id then
      lines[#lines + 1] = "  diff: " .. tostring(entry.diff_session_id)
    end
  end
  return lines
end

function M.show_at_cursor(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    vim.notify("nvime attribution: buffer has no file", vim.log.levels.INFO)
    return
  end
  local rel = git.repo_relative_path(name) or name
  local lineno = vim.api.nvim_win_get_cursor(0)[1]
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local matches = M.for_line(rel, lineno, buf_lines)
  if #matches == 0 then
    vim.notify("nvime blame: no recorded entry covers this line", vim.log.levels.INFO)
    return nil
  end
  local lines = build_blame_lines(rel, lineno, matches)
  if opts.notify then
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return matches
  end
  open_blame_popup(lines, { title = "nvime blame · " .. rel })
  return matches
end

M.close_popup = close_blame_popup
M._build_blame_lines = build_blame_lines

-- Compact relative age ("3d", "2w", "5m") for the gutter overlay, so a glance
-- shows not just WHO authored a line but HOW STALE the AI authorship is — old
-- AI lines that have survived review read very differently from fresh ones.
local function relative_age(ts)
  ts = tonumber(ts)
  if not ts or ts <= 0 then
    return nil
  end
  local delta = os.time() - ts
  if delta < 0 then
    delta = 0
  end
  if delta < 3600 then
    return string.format("%dm", math.max(1, math.floor(delta / 60)))
  elseif delta < 86400 then
    return string.format("%dh", math.floor(delta / 3600))
  elseif delta < 86400 * 7 then
    return string.format("%dd", math.floor(delta / 86400))
  elseif delta < 86400 * 365 then
    return string.format("%dw", math.floor(delta / (86400 * 7)))
  end
  return string.format("%dy", math.floor(delta / (86400 * 365)))
end

M._relative_age = relative_age

local function clear_overlay(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, OVERLAY_NS, 0, -1)
  vim.b[bufnr].nvime_attribution_overlay = false
end

local function paint_overlay(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return
  end
  local rel = git.repo_relative_path(name) or name
  local entries = M.for_file(rel)
  if #entries == 0 then
    return
  end
  -- The overlay paints into a real source buffer, which may be the first nvime
  -- surface shown this session; make sure our highlight groups are defined.
  require("nvime.ui").ensure_highlights()
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  vim.api.nvim_buf_clear_namespace(bufnr, OVERLAY_NS, 0, -1)
  local seen_lines = {}
  for _, entry in ipairs(entries) do
    local first, last = locate_anchor(buf_lines, entry)
    if first then
      for ln = first, last do
        if not seen_lines[ln] then
          seen_lines[ln] = true
          local label_parts = { entry.plan_id and (entry.plan_id .. " s" .. tostring(entry.step_id or "?")) or "edit" }
          if entry.forced then
            label_parts[#label_parts + 1] = "FORCED"
          end
          if type(entry.verdict) == "table" and entry.verdict.decision then
            label_parts[#label_parts + 1] = entry.verdict.decision
          end
          local age = relative_age(entry.ts)
          if age then
            label_parts[#label_parts + 1] = age
          end
          -- Route through nvime's colorscheme-derived groups so the overlay
          -- matches every other surface (muted meta, warn for forced accepts,
          -- error for a critic REJECT) instead of raw standard groups.
          local hl = "NvimeMuted"
          if entry.forced then
            hl = "NvimeStatusWarn"
          elseif type(entry.verdict) == "table" and entry.verdict.decision == "REJECT" then
            hl = "NvimeStatusError"
          end
          local label = "  ▎ " .. table.concat(label_parts, " · ")
          pcall(vim.api.nvim_buf_set_extmark, bufnr, OVERLAY_NS, ln - 1, 0, {
            virt_text = { { label, hl } },
            virt_text_pos = "eol",
          })
        end
      end
    end
  end
  vim.b[bufnr].nvime_attribution_overlay = true
end

function M.toggle_overlay(bufnr, mode)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local current = vim.b[bufnr].nvime_attribution_overlay == true
  if mode == "show" or (mode == nil and not current) then
    paint_overlay(bufnr)
  else
    clear_overlay(bufnr)
  end
end

function M._build_anchor(lines)
  return build_anchor(lines)
end

function M._locate_anchor(buf_lines, entry)
  return locate_anchor(buf_lines, entry)
end

return M
