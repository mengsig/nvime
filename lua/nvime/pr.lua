-- nvime.pr
--
-- PR sidecar. Reads the attribution ledger plus a window of audit events,
-- intersects them with the changed files between a base ref and HEAD, and
-- emits `.nvime/pr.md` — a single Markdown page a human reviewer can read
-- to see exactly what was AI-attributed on this branch, with rationales,
-- critic verdicts, and any force-accepts or policy overrides flagged.
--
-- This is the human-facing antidote to "nobody reviewed the AI work".

local audit = require("nvime.audit")
local git = require("nvime.git")
local state = require("nvime.state")

local M = {}

local function cfg()
  return (state.config or {}).pr or {}
end

local function repo_root()
  return git.root((vim.uv or vim.loop).cwd()) or (vim.uv or vim.loop).cwd()
end

local function pr_path()
  local override = cfg().path
  if type(override) == "string" and override ~= "" then
    return vim.fn.fnamemodify(override, ":p")
  end
  return repo_root() .. "/.nvime/pr.md"
end

local function detect_base()
  local override = cfg().base_branch
  if type(override) == "string" and override ~= "" then
    return override
  end
  local root = repo_root()
  -- Try common candidates in order.
  for _, ref in ipairs({ "origin/main", "main", "origin/master", "master" }) do
    local out = git.systemlist({ "git", "-C", root, "rev-parse", "--verify", "--quiet", ref })
    if out and out[1] and out[1] ~= "" then
      return ref
    end
  end
  return "HEAD~1"
end

local function git_commits_between(base, head)
  local root = repo_root()
  local out = git.systemlist({
    "git", "-C", root, "log",
    "--reverse", "--format=%H%x00%ct%x00%s",
    base .. ".." .. head,
  })
  local commits = {}
  for _, line in ipairs(out or {}) do
    local sha, ts, subject = line:match("^([^%z]+)%z([^%z]+)%z(.+)$")
    if sha then
      commits[#commits + 1] = {
        sha = sha,
        ts = tonumber(ts) or 0,
        subject = subject,
      }
    end
  end
  return commits
end

local function changed_files(base, head)
  local root = repo_root()
  local out = git.systemlist({
    "git", "-C", root, "diff", "--name-only", base .. "..." .. head,
  })
  local files = {}
  for _, name in ipairs(out or {}) do
    if name ~= "" then
      files[#files + 1] = name
    end
  end
  return files
end

local function attribution_entries()
  local ok, attribution = pcall(require, "nvime.attribution")
  if not ok then
    return {}
  end
  local ledger_ok, ledger = pcall(attribution.read)
  if not ledger_ok or type(ledger) ~= "table" then
    return {}
  end
  return ledger.entries or {}
end

local function risky_audit_events(since_ts)
  local ok, digest = pcall(require, "nvime.digest")
  if not ok then
    return {}
  end
  local events = digest.read_events({ since_ts = since_ts or 0 })
  local out = {}
  for _, event in ipairs(events) do
    local kind = event.event
    if
      kind == "verify_force"
      or kind == "verify_block"
      or kind == "risk_force"
      or kind == "block_force_applied"
      or kind == "policy_block"
      or kind == "intent_override"
    then
      out[#out + 1] = event
    end
  end
  return out
end

local function group_entries_by_file(entries, changed_set)
  local by_file = {}
  for _, entry in ipairs(entries) do
    local file = entry.file
    if file and changed_set[file] then
      by_file[file] = by_file[file] or {}
      by_file[file][#by_file[file] + 1] = entry
    end
  end
  return by_file
end

local function format_entry(entry)
  local lines = {}
  local id
  if entry.plan_id then
    id = string.format("plan %s · step %s", entry.plan_id, tostring(entry.step_id or "?"))
  else
    id = "edit"
  end
  local forced = entry.forced and " · **FORCED**" or ""
  lines[#lines + 1] = string.format("- %s · `%s`%s", id, entry.provider or entry.model or "?", forced)
  if entry.rationale and entry.rationale ~= "" then
    lines[#lines + 1] = "  - rationale: " .. entry.rationale
  end
  if type(entry.verdict) == "table" and entry.verdict.decision then
    lines[#lines + 1] = string.format("  - critic %s: %s",
      entry.verdict.decision, entry.verdict.justification or "")
  end
  if entry.iso_ts or entry.ts then
    lines[#lines + 1] = "  - " .. (entry.iso_ts or os.date("!%Y-%m-%dT%H:%M:%SZ", entry.ts or 0))
  end
  return lines
end

local function format_risky(event)
  local label = event.event
  local detail
  if label == "verify_force" or label == "verify_block" then
    detail = string.format("%s · %s", event.file or "?", event.reason or "?")
  elseif label == "risk_force" then
    detail = string.format("%s · %s · +%d −%d ai %d%%",
      event.file or "?", event.level or "?",
      tonumber(event.lines_added) or 0,
      tonumber(event.lines_removed) or 0,
      math.floor(((tonumber(event.ai_share) or 0)) * 100 + 0.5))
  elseif label == "block_force_applied" then
    detail = string.format("%s:%d-%d", event.file or "?", event.start_line or -1, event.end_line or -1)
  elseif label == "policy_block" then
    detail = string.format("%s · lane %s · %s", event.file or "?", event.lane or "?", event.reason or "?")
  elseif label == "intent_override" then
    detail = string.format("lane %s · %s", event.lane or "?", event.reason or "?")
  else
    detail = vim.inspect(event):sub(1, 80)
  end
  return string.format("- `%s` — %s", label, detail)
end

-- Public: render the PR sidecar. Returns the text and the path written.
function M.render(opts)
  opts = opts or {}
  local base = opts.base or detect_base()
  local head = opts.head or "HEAD"
  local include_unattributed = cfg().include_unattributed ~= false

  local commits = git_commits_between(base, head)
  local files = changed_files(base, head)
  local changed_set = {}
  for _, file in ipairs(files) do
    changed_set[file] = true
  end

  -- Window starts at the oldest commit in the range; risky events older
  -- than that aren't part of this branch's story.
  local since = math.huge
  for _, commit in ipairs(commits) do
    if commit.ts < since then
      since = commit.ts
    end
  end
  if since == math.huge then
    since = 0
  end

  local entries = attribution_entries()
  local by_file = group_entries_by_file(entries, changed_set)
  local risky = risky_audit_events(since)

  local lines = {}
  table.insert(lines, "# nvime PR sidecar")
  table.insert(lines, "")
  table.insert(lines, string.format("Base: `%s` · Head: `%s` · %d commits · %d files changed",
    base, head, #commits, #files))
  table.insert(lines, "")
  if #risky > 0 then
    table.insert(lines, "## Review-first events")
    table.insert(lines, "")
    table.insert(lines, "These bypassed a nvime gate or recorded a forced action — read these first.")
    table.insert(lines, "")
    for _, event in ipairs(risky) do
      table.insert(lines, format_risky(event))
    end
    table.insert(lines, "")
  end
  table.insert(lines, "## AI-attributed changes")
  table.insert(lines, "")
  local attributed_count = 0
  for file, file_entries in pairs(by_file) do
    if #file_entries > 0 then
      attributed_count = attributed_count + #file_entries
      table.insert(lines, "### `" .. file .. "`")
      for _, entry in ipairs(file_entries) do
        for _, l in ipairs(format_entry(entry)) do
          table.insert(lines, l)
        end
      end
      table.insert(lines, "")
    end
  end
  if attributed_count == 0 then
    table.insert(lines, "_No attribution entries overlap this branch's changed files._")
    table.insert(lines, "")
  end
  if include_unattributed then
    local unattributed = {}
    for _, file in ipairs(files) do
      if not by_file[file] or #(by_file[file] or {}) == 0 then
        unattributed[#unattributed + 1] = file
      end
    end
    if #unattributed > 0 then
      table.insert(lines, "## Changed files without nvime attribution")
      table.insert(lines, "")
      table.insert(lines, "Reviewer note: these files were modified on this branch but have no")
      table.insert(lines, "nvime attribution. They are either human-written or were edited outside")
      table.insert(lines, "the nvime lanes.")
      table.insert(lines, "")
      for _, file in ipairs(unattributed) do
        table.insert(lines, "- `" .. file .. "`")
      end
      table.insert(lines, "")
    end
  end

  local body = table.concat(lines, "\n")
  if opts.dry_run then
    return body, nil
  end
  local path = pr_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "w")
  if not fd then
    return nil, err
  end
  local write_ok, write_err = pcall(function()
    fd:write(body)
  end)
  pcall(function()
    fd:close()
  end)
  if not write_ok then
    return nil, write_err
  end
  audit.write({
    event = "pr_sidecar",
    path = path,
    base = base,
    head = head,
    files = #files,
    commits = #commits,
    attributed = attributed_count,
    risky_events = #risky,
  })
  return body, path
end

return M
