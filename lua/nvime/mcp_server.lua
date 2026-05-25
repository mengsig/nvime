-- nvime.mcp_server
--
-- A minimal MCP (Model Context Protocol) server over stdio. Spoken in
-- JSON-RPC 2.0; Content-Length framed messages are NOT used here — Claude
-- accepts the simpler newline-delimited form for stdio servers.
--
-- Exposed tools (all read-only):
--   Project bookkeeping:
--     nvime.search_attribution(file, line)   — agent-attribution entries for a line
--     nvime.list_plans()                     — list .nvime/plans/<id>/ entries
--     nvime.get_plan(id)                     — return plan.json + plan.md (truncated)
--     nvime.recent_audits(limit, kind)       — tail of audit.jsonl, optional kind filter
--     nvime.recent_diffs(limit)              — tail of accepted-diff metadata for the agent
--     nvime.usage_summary()                  — usage ledger summary
--   Code intelligence:
--     nvime.tree_sitter_symbols(file)        — definition-like symbol list for a file
--     nvime.git_log(path?, limit?)           — recent commits, optionally scoped to a path
--     nvime.git_blame(path, line)            — blame metadata for a specific line
--   Verification + memory:
--     nvime.test_run(runner?, timeout?)      — run the configured/auto-detected test runner
--     nvime.verify_file(file, content?,      — pre-accept verify lane (parse+lint+type)
--                       wait_ms?)               match the protocol VERIFY: line to status
--     nvime.session_search(query, limit?)    — full-text search across past chat transcripts
--     nvime.session_recent(limit?)           — most recently updated chat sessions (titles)
--
-- Spawn invocation (used by nvime.mcp's default self-server entry):
--   nvim --headless --clean --cmd "set rtp+=<root>" --cmd "lua require('nvime.mcp_server').run()"
--
-- The server inherits cwd from claude (which agents.lua sets to repo_root),
-- and NVIME_REPO_ROOT is set in env so .nvime/ is reachable.

local M = {}

local uv = vim.uv or vim.loop

local SERVER_INFO = { name = "nvime", version = "0.1.0" }
local PROTOCOL_VERSION = "2025-03-26"

-- Versions we know we can speak. If the client asks for one of these we
-- echo it back; otherwise we answer with PROTOCOL_VERSION and let the
-- client decide whether to downgrade. Spec forbids advertising a version
-- we don't actually implement.
local SUPPORTED_PROTOCOL_VERSIONS = {
  ["2025-03-26"] = true,
  ["2024-11-05"] = true,
}

-- Resource bounds. Keeping them as named constants makes the contract
-- with callers explicit and avoids "magic 5000" sprinkled across tools.
local AUDIT_READ_LINES = 5000 -- how far back into audit.jsonl we scan
local TAIL_LINES_DEFAULT = 200 -- default cap for stdout/stderr tails
local TIMEOUT_DEFAULT_MS = 60000
local TIMEOUT_MAX_MS = 300000
local MAX_PARSE_BYTES = 4 * 1024 * 1024 -- tree-sitter walk size limit
local MAX_CAPTURE_BYTES = 2 * 1024 * 1024 -- per-stream cap for test_run

-- The diff.lua → audit.write event name that recent_diffs filters on.
-- Both producer and consumer should resolve to this constant.
local DIFF_RESOLVED_EVENT = "diff_resolved"

local TOOLS = {
  {
    name = "nvime.search_attribution",
    description = "Return agent-attribution entries (rationale, plan id, critic verdict) for a (file, line). Reads .nvime/attribution.json.",
    inputSchema = {
      type = "object",
      properties = {
        file = { type = "string", description = "Repo-relative path to the file." },
        line = { type = "integer", description = "1-based line number to query." },
      },
      required = { "file", "line" },
    },
  },
  {
    name = "nvime.list_plans",
    description = "List nvime plans stored under .nvime/plans/<id>/. Returns id, title, status, step count for each.",
    inputSchema = {
      type = "object",
      properties = vim.empty_dict(),
    },
  },
  {
    name = "nvime.get_plan",
    description = "Return the plan.json metadata and a truncated plan.md narrative for the given plan id.",
    inputSchema = {
      type = "object",
      properties = {
        id = { type = "string", description = "Plan id (the directory name under .nvime/plans/)." },
      },
      required = { "id" },
    },
  },
  {
    name = "nvime.recent_audits",
    description = "Return the most recent N entries from .nvime/audit.jsonl (newest last). Optional `kind` filters by event field.",
    inputSchema = {
      type = "object",
      properties = {
        limit = { type = "integer", description = "How many entries (default 50, max 500)." },
        kind = { type = "string", description = "Filter by audit event kind (e.g. agent_exit, blocked)." },
      },
    },
  },
  {
    name = "nvime.usage_summary",
    description = "Return the nvime token + cost ledger summary (totals, by_lane, recent days).",
    inputSchema = {
      type = "object",
      properties = vim.empty_dict(),
    },
  },
  {
    name = "nvime.tree_sitter_symbols",
    description = "Return a flat list of definition-like symbols (functions/methods/classes/structs/modules) in `file`. Each entry: { kind, name, line_start, line_end, parent }. Tree-sitter parser for the file's filetype must be available in the host nvim's runtime path; otherwise the tool returns an error and the caller should fall back to Read.",
    inputSchema = {
      type = "object",
      properties = {
        file = { type = "string", description = "Repo-relative path to the file." },
      },
      required = { "file" },
    },
  },
  {
    name = "nvime.git_log",
    description = "Return the most recent commits touching `path` (or the whole repo when path is omitted). Each entry: { sha, author, date, subject }. Read-only; no working-tree mutation.",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Optional repo-relative path to scope the log to." },
        limit = { type = "integer", description = "Max commits to return (default 20, max 200)." },
      },
    },
  },
  {
    name = "nvime.git_blame",
    description = "Return blame metadata for a single line: { sha, author, author_mail, author_time, summary, line }. Useful for `who/why was this line written?`",
    inputSchema = {
      type = "object",
      properties = {
        path = { type = "string", description = "Repo-relative path to the file." },
        line = { type = "integer", description = "1-based line number to query." },
      },
      required = { "path", "line" },
    },
  },
  {
    name = "nvime.test_run",
    description = "Run the project's test runner and return the tail of stdout+stderr plus exit code. The runner is `runner` if supplied, else state.config.test_loop.runner / state.config.plan.test_runner, else auto-detected from project markers (Cargo.toml, package.json, scripts/test, etc.). Bounded by `timeout` ms (default 60000, max 300000).",
    inputSchema = {
      type = "object",
      properties = {
        runner = {
          type = "string",
          description = "Optional explicit shell command to run instead of the configured/detected one.",
        },
        timeout = { type = "integer", description = "Wall-clock cap in milliseconds (default 60000, max 300000)." },
      },
    },
  },
  {
    name = "nvime.session_search",
    description = "Case-insensitive full-text search across stored chat transcripts (.nvime/chat-sessions.json + .nvime/selection-sessions.json). Returns { session_id, title, role, snippet, ts } for each match. Useful for `did I solve this before?`",
    inputSchema = {
      type = "object",
      properties = {
        query = { type = "string", description = "Substring to look for (case-insensitive)." },
        limit = { type = "integer", description = "Max matches to return (default 20, max 200)." },
      },
      required = { "query" },
    },
  },
  {
    name = "nvime.session_recent",
    description = "Return the N most recently updated chat sessions (title, id, provider, last update, message count). Drawn from .nvime/chat-sessions.json + .nvime/selection-sessions.json.",
    inputSchema = {
      type = "object",
      properties = {
        limit = { type = "integer", description = "Max sessions to return (default 10, max 100)." },
      },
    },
  },
  {
    name = "nvime.recent_diffs",
    description = "Return the most recent accepted-diff metadata derived from audit.jsonl: { path, accepted, rationale, verdict, ts, plan_id }. Lets a fresh chat session learn what's been worked on without re-reading source.",
    inputSchema = {
      type = "object",
      properties = {
        limit = { type = "integer", description = "Max entries to return (default 20, max 200)." },
      },
    },
  },
  {
    name = "nvime.verify_file",
    description = "Run nvime's pre-accept verify lane against an arbitrary path + content: tree-sitter parse plus configured lint/type checks (ruff, shellcheck, luacheck/selene, gofmt, zig ast-check, mypy, plus user-configured commands). Returns { status, parse_error, findings, by_check }. Intended for self-check BEFORE emitting NVIME_DIFF — match the protocol `VERIFY:` line to the returned status.",
    inputSchema = {
      type = "object",
      properties = {
        file = { type = "string", description = "Repo-relative path. Used for glob matching and project-config resolution. The file does not have to exist on disk when `content` is supplied." },
        content = { type = "string", description = "Proposed full-file content to verify. If omitted, the on-disk file is read." },
        wait_ms = { type = "integer", description = "How long to wait for external checks before returning (default 0 — parse-only). Max 60000." },
      },
      required = { "file" },
    },
  },
}

local function repo_root()
  -- Honor NVIME_REPO_ROOT first; the host (claude) often spawns this
  -- server from a transient scratch cwd, so cwd-based discovery would
  -- pick the wrong tree.
  local explicit = vim.env.NVIME_REPO_ROOT
  if explicit and explicit ~= "" and vim.fn.isdirectory(explicit) == 1 then
    return explicit
  end
  local ok_git, git = pcall(require, "nvime.git")
  if ok_git then
    return git.repo_root(uv.cwd())
  end
  return uv.cwd()
end

local function nvime_path(rel)
  return repo_root() .. "/.nvime/" .. rel
end

-- Reject relative paths whose normalized form escapes a base directory.
-- MCP tools accept user-supplied `file` / `id` strings; without this guard
-- a caller could read arbitrary filesystem locations via "../../etc/...".
local function safe_join(base, rel)
  if type(rel) ~= "string" or rel == "" then
    return nil, "empty path"
  end
  if rel:sub(1, 1) == "/" then
    return nil, "absolute paths not allowed"
  end
  for segment in rel:gmatch("[^/]+") do
    if segment == ".." then
      return nil, "parent traversal not allowed"
    end
  end
  local joined = base .. "/" .. rel
  local base_real = uv.fs_realpath(base)
  local target_real = uv.fs_realpath(joined)
  if base_real and target_real then
    if target_real ~= base_real and target_real:sub(1, #base_real + 1) ~= base_real .. "/" then
      return nil, "path escapes repository"
    end
  end
  return joined
end

local function ok_text(text)
  return { content = { { type = "text", text = text or "" } } }
end

local function ok_json(value)
  local encoded
  local enc_ok, encoded_or_err = pcall(vim.json.encode, value)
  if enc_ok then
    encoded = encoded_or_err
  else
    encoded = "(failed to encode result: " .. tostring(encoded_or_err) .. ")"
  end
  return ok_text(encoded)
end

local function err_result(message)
  return { content = { { type = "text", text = "error: " .. tostring(message) } }, isError = true }
end

local function read_lines(path, limit)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return nil
  end
  if limit and #lines > limit then
    local out = {}
    for i = #lines - limit + 1, #lines do
      out[#out + 1] = lines[i]
    end
    return out
  end
  return lines
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
  if not decoded_ok then
    return nil
  end
  return decoded
end

local function tool_search_attribution(args)
  local file = args.file
  local line = tonumber(args.line)
  if not file or not line then
    return err_result("file and line are required")
  end
  local target, perr = safe_join(repo_root(), file)
  if not target then
    return err_result("invalid file: " .. perr)
  end
  local ok, attribution = pcall(require, "nvime.attribution")
  if not ok then
    return err_result("attribution module unavailable")
  end
  local buf_lines = vim.fn.filereadable(target) == 1 and vim.fn.readfile(target) or {}
  local matches = attribution.for_line(file, line, buf_lines) or {}
  return ok_json({ file = file, line = line, matches = matches })
end

local function tool_list_plans(_)
  local plans_dir = nvime_path("plans")
  if vim.fn.isdirectory(plans_dir) ~= 1 then
    return ok_json({ plans = {} })
  end
  local entries = {}
  local scanner = uv.fs_scandir(plans_dir)
  if not scanner then
    return ok_json({ plans = {} })
  end
  while true do
    local name, kind = uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    if kind == "directory" then
      local plan = read_json(plans_dir .. "/" .. name .. "/plan.json")
      local steps = (plan and plan.steps) or {}
      entries[#entries + 1] = {
        id = name,
        title = plan and plan.title or nil,
        status = plan and plan.status or nil,
        steps = #steps,
        provider = plan and plan.provider or nil,
        updated_at = plan and plan.updated_at or nil,
      }
    end
  end
  table.sort(entries, function(a, b)
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)
  return ok_json({ plans = entries })
end

local function tool_get_plan(args)
  local id = args.id
  if not id or id == "" then
    return err_result("id is required")
  end
  local dir, perr = safe_join(nvime_path("plans"), id)
  if not dir then
    return err_result("invalid id: " .. perr)
  end
  if vim.fn.isdirectory(dir) ~= 1 then
    return err_result("no such plan: " .. id)
  end
  local plan = read_json(dir .. "/plan.json")
  local md_path = dir .. "/plan.md"
  local md_text = nil
  if vim.fn.filereadable(md_path) == 1 then
    local lines = read_lines(md_path, 600)
    md_text = table.concat(lines or {}, "\n")
  end
  return ok_json({ id = id, plan = plan, plan_md = md_text })
end

-- Walk the most recent AUDIT_READ_LINES of audit.jsonl, decode each
-- line, and yield those passing `predicate(decoded)`. `project(decoded)`
-- maps each surviving record into the shape callers actually want.
-- Output is ordered oldest-first within the matched slice.
local function audit_tail(predicate, project, limit)
  local lines = read_lines(nvime_path("audit.jsonl"), AUDIT_READ_LINES) or {}
  local out = {}
  for i = #lines, 1, -1 do
    local ok, decoded = pcall(vim.json.decode, lines[i])
    if ok and predicate(decoded) then
      out[#out + 1] = project(decoded)
      if #out >= limit then
        break
      end
    end
  end
  local ordered = {}
  for i = #out, 1, -1 do
    ordered[#ordered + 1] = out[i]
  end
  return ordered
end

local function tool_recent_audits(args)
  local limit = math.min(tonumber(args.limit) or 50, 500)
  local kind = args.kind
  local ordered = audit_tail(function(decoded)
    return type(decoded) == "table" and (not kind or decoded.event == kind)
  end, function(decoded)
    return decoded
  end, limit)
  return ok_json({ audits = ordered, count = #ordered, filter = kind })
end

local function tool_usage_summary(_)
  local ok, usage = pcall(require, "nvime.usage")
  if not ok then
    return err_result("usage module unavailable")
  end
  return ok_text(usage.summary_text())
end

local function tool_tree_sitter_symbols(args)
  local file = args.file
  if not file or file == "" then
    return err_result("file is required")
  end
  local target, perr = safe_join(repo_root(), file)
  if not target then
    return err_result("invalid file: " .. perr)
  end
  if vim.fn.filereadable(target) ~= 1 then
    return err_result("no such file: " .. file)
  end
  local size = vim.fn.getfsize(target)
  if size and size > MAX_PARSE_BYTES then
    return err_result(string.format("file too large to parse (%d bytes > %d cap)", size, MAX_PARSE_BYTES))
  end
  local ok_ts, ts = pcall(require, "nvime.treesitter")
  if not ok_ts then
    return err_result("treesitter module unavailable")
  end
  local bufnr = vim.fn.bufadd(target)
  vim.fn.bufload(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return err_result("could not load buffer for " .. file)
  end
  if vim.bo[bufnr].filetype == "" then
    local ft = vim.filetype.match({ filename = file })
    if ft then
      vim.bo[bufnr].filetype = ft
    end
  end
  local symbols, walk_err = ts.walk_symbols(bufnr)
  if not symbols then
    return err_result(
      (walk_err or "tree-sitter walk failed")
        .. " (filetype="
        .. (vim.bo[bufnr].filetype ~= "" and vim.bo[bufnr].filetype or "?")
        .. "; the parser must be in this nvim's runtimepath — install it or expose your live nvim's RTP via mcp.self_command)"
    )
  end
  return ok_json({ file = file, filetype = vim.bo[bufnr].filetype, symbols = symbols, count = #symbols })
end

-- Run `git -C <repo_root> <args>` and return stdout, or nil + stderr when
-- git itself failed. Uses vim.system's built-in capture (no callbacks)
-- since these subcommands are short and finish quickly.
local function git_run(extra)
  local args = { "git", "-C", repo_root() }
  for _, a in ipairs(extra) do
    args[#args + 1] = a
  end
  local result = vim.system(args, { text = true }):wait()
  if result.code ~= 0 then
    local err = (result.stderr ~= "" and result.stderr) or ("git exited " .. tostring(result.code))
    return nil, err
  end
  return result.stdout or ""
end

local function tool_git_log(args)
  local limit = math.min(math.max(tonumber(args.limit) or 20, 1), 200)
  local path = args.path
  -- ASCII unit/record separators keep parsing safe even when commit
  -- subjects contain tabs or newlines.
  local US, RS = "\31", "\30"
  local extra = {
    "log",
    "-n",
    tostring(limit),
    "--pretty=format:%H" .. US .. "%an" .. US .. "%aI" .. US .. "%s" .. RS,
    "--no-color",
  }
  if path and path ~= "" then
    local _, perr = safe_join(repo_root(), path)
    if perr then
      return err_result("invalid path: " .. perr)
    end
    extra[#extra + 1] = "--"
    extra[#extra + 1] = path
  end
  local out, err = git_run(extra)
  if not out then
    return err_result("git log failed: " .. (err or ""))
  end
  local commits = {}
  for record in out:gmatch("([^" .. RS .. "]+)") do
    local sha, author, date, subject =
      record:match("^([^" .. US .. "]+)" .. US .. "([^" .. US .. "]+)" .. US .. "([^" .. US .. "]+)" .. US .. "(.*)$")
    if sha then
      commits[#commits + 1] = { sha = sha, author = author, date = date, subject = subject or "" }
    end
  end
  return ok_json({ path = path, count = #commits, commits = commits })
end

local function tool_git_blame(args)
  local path = args.path
  local line = tonumber(args.line)
  if not path or not line then
    return err_result("path and line are required")
  end
  local target, perr = safe_join(repo_root(), path)
  if not target then
    return err_result("invalid path: " .. perr)
  end
  if vim.fn.filereadable(target) ~= 1 then
    return err_result("no such file: " .. path)
  end
  local out, err = git_run({
    "blame",
    "--line-porcelain",
    "-L",
    string.format("%d,%d", line, line),
    "--",
    path,
  })
  if not out then
    return err_result("git blame failed: " .. (err or ""))
  end
  local entry = { line = line, path = path }
  for chunk in out:gmatch("[^\n]+") do
    local sha = chunk:match("^([0-9a-f]+) ")
    if sha and not entry.sha then
      entry.sha = sha
    end
    local key, value = chunk:match("^(%S+) (.*)$")
    if key == "author" then
      entry.author = value
    elseif key == "author-mail" then
      entry.author_mail = value
    elseif key == "author-time" then
      entry.author_time = tonumber(value)
    elseif key == "summary" then
      entry.summary = value
    elseif key == "previous" then
      entry.previous_sha = value:match("^(%S+)")
    end
    if chunk:sub(1, 1) == "\t" then
      entry.source_line = chunk:sub(2)
    end
  end
  if entry.author_time then
    entry.author_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", entry.author_time)
  end
  -- git blame returns a synthetic all-zero sha for lines that aren't
  -- committed yet (working-tree edits or staged-but-not-committed). Flag
  -- the result so callers don't mistake "Not Committed Yet" for real
  -- blame data.
  if entry.sha and entry.sha:match("^0+$") then
    entry.uncommitted = true
  end
  return ok_json(entry)
end

local function detected_runner()
  local ok_plan, plan = pcall(require, "nvime.plan")
  if ok_plan and type(plan.detect_test_runner) == "function" then
    return plan.detect_test_runner()
  end
  return nil
end

local function configured_runner()
  local ok, state = pcall(require, "nvime.state")
  if not ok then
    return nil
  end
  local cfg = state.config or {}
  local tl = cfg.test_loop or {}
  if type(tl.runner) == "string" and tl.runner ~= "" then
    return tl.runner
  end
  local p = cfg.plan or {}
  if type(p.test_runner) == "string" and p.test_runner ~= "" then
    return p.test_runner
  end
  return nil
end

-- Cap a captured stream to its trailing N lines. Preserves blank lines
-- (vim.split with plain=true keeps empty entries) so the output the
-- agent sees lines up with what a human reading stdout would see.
local function tail_stream(text, limit)
  if not text or text == "" then
    return text or ""
  end
  limit = limit or TAIL_LINES_DEFAULT
  local lines = vim.split(text, "\n", { plain = true })
  if #lines <= limit then
    return text
  end
  local out = {}
  for i = #lines - limit + 1, #lines do
    out[#out + 1] = lines[i]
  end
  return "[truncated " .. tostring(#lines - limit) .. " earlier lines]\n" .. table.concat(out, "\n")
end

-- Bound the in-memory chunk array so a runaway runner can't OOM the
-- server before its timeout fires. Returned closure tracks total bytes;
-- once `cap` is exceeded it stops appending and records that we truncated.
local function bounded_collector(cap)
  local chunks = {}
  local size = 0
  local truncated = false
  return function(_, data)
    if not data or truncated then
      return
    end
    size = size + #data
    if size > cap then
      chunks[#chunks + 1] = "\n[stream truncated at " .. tostring(cap) .. " bytes]\n"
      truncated = true
      return
    end
    chunks[#chunks + 1] = data
  end, function()
    return table.concat(chunks)
  end
end

local function tool_test_run(args)
  local runner = (args.runner and args.runner ~= "" and args.runner) or configured_runner() or detected_runner()
  if not runner then
    return err_result("no test runner configured or detected for this project")
  end
  local timeout = math.min(math.max(tonumber(args.timeout) or TIMEOUT_DEFAULT_MS, 1000), TIMEOUT_MAX_MS)
  local on_stdout, read_stdout = bounded_collector(MAX_CAPTURE_BYTES)
  local on_stderr, read_stderr = bounded_collector(MAX_CAPTURE_BYTES)
  -- sh -c (NOT -lc): a login shell sources profile and may cd to $HOME,
  -- defeating the cwd we set. vim.system's `timeout` option SIGKILLs the
  -- child after the deadline and reports code=124, so we don't need to
  -- hand-roll the watchdog.
  local started = uv.hrtime()
  local result = vim
    .system({ "sh", "-c", runner }, {
      text = true,
      cwd = repo_root(),
      env = require("nvime.shellguard").build_env(),
      timeout = timeout,
      stdout = on_stdout,
      stderr = on_stderr,
    })
    :wait()
  local elapsed_ms = math.floor((uv.hrtime() - started) / 1e6)
  return ok_json({
    runner = runner,
    exit_code = result.code,
    signal = result.signal,
    duration_ms = elapsed_ms,
    timed_out = result.code == 124,
    stdout_tail = tail_stream(read_stdout()),
    stderr_tail = tail_stream(read_stderr()),
  })
end

local function read_session_files()
  local out = {}
  for _, rel in ipairs({ "chat-sessions.json", "selection-sessions.json" }) do
    local decoded = read_json(nvime_path(rel))
    if decoded and type(decoded.sessions) == "table" then
      out[#out + 1] = { source = rel, decoded = decoded }
    end
  end
  return out
end

local function tool_session_search(args)
  local query = args.query
  if type(query) ~= "string" or query == "" then
    return err_result("query is required")
  end
  local limit = math.min(math.max(tonumber(args.limit) or 20, 1), 200)
  local needle = query:lower()
  local matches = {}
  local function snippet(text, idx)
    local start = math.max(1, idx - 60)
    local stop = math.min(#text, idx + 60 + #needle)
    return text:sub(start, stop):gsub("\n", " ")
  end
  for _, file in ipairs(read_session_files()) do
    for _, session in ipairs(file.decoded.sessions or {}) do
      local history = session.history or {}
      for _, msg in ipairs(history) do
        local content = type(msg.content) == "string" and msg.content or ""
        if content ~= "" then
          local pos = content:lower():find(needle, 1, true)
          if pos then
            matches[#matches + 1] = {
              source = file.source,
              session_id = session.id,
              title = session.title,
              role = msg.role,
              snippet = snippet(content, pos),
              ts = session.updated_at,
            }
            if #matches >= limit then
              return ok_json({ query = query, count = #matches, matches = matches })
            end
          end
        end
      end
    end
  end
  return ok_json({ query = query, count = #matches, matches = matches })
end

local function tool_session_recent(args)
  local limit = math.min(math.max(tonumber(args.limit) or 10, 1), 100)
  local rows = {}
  for _, file in ipairs(read_session_files()) do
    for _, session in ipairs(file.decoded.sessions or {}) do
      local history = session.history or {}
      rows[#rows + 1] = {
        source = file.source,
        session_id = session.id,
        title = session.title,
        provider = session.provider,
        last_provider = session.last_provider,
        updated_at = session.updated_at,
        created_at = session.created_at,
        message_count = #history,
      }
    end
  end
  table.sort(rows, function(a, b)
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)
  local trimmed = {}
  for i = 1, math.min(limit, #rows) do
    trimmed[i] = rows[i]
  end
  return ok_json({ count = #trimmed, sessions = trimmed })
end

local function tool_recent_diffs(args)
  local limit = math.min(math.max(tonumber(args.limit) or 20, 1), 200)
  local ordered = audit_tail(function(decoded)
    return type(decoded) == "table" and decoded.event == DIFF_RESOLVED_EVENT
  end, function(decoded)
    return {
      path = decoded.path,
      accepted = decoded.accepted,
      total = decoded.total,
      rationale = decoded.rationale,
      verdict = decoded.verdict,
      plan_id = decoded.plan_id,
      plan_step_id = decoded.plan_step_id,
      ts = decoded.ts,
      provider = decoded.provider,
    }
  end, limit)
  return ok_json({ count = #ordered, diffs = ordered })
end

local function tool_verify_file(args)
  local file = args.file
  if not file or file == "" then
    return err_result("file is required")
  end
  local target, perr = safe_join(repo_root(), file)
  if not target then
    return err_result("invalid file: " .. perr)
  end
  local wait_ms = tonumber(args.wait_ms) or 0
  if wait_ms < 0 then
    wait_ms = 0
  end
  if wait_ms > 60000 then
    wait_ms = 60000
  end
  local ok_verify, verify = pcall(require, "nvime.verify")
  if not ok_verify or not verify or type(verify.verify_path) ~= "function" then
    return err_result("verify module unavailable")
  end
  local result = verify.verify_path(target, args.content, { wait_ms = wait_ms })
  result.file = file
  return ok_json(result)
end

local TOOL_HANDLERS = {
  ["nvime.search_attribution"] = tool_search_attribution,
  ["nvime.list_plans"] = tool_list_plans,
  ["nvime.get_plan"] = tool_get_plan,
  ["nvime.recent_audits"] = tool_recent_audits,
  ["nvime.usage_summary"] = tool_usage_summary,
  ["nvime.tree_sitter_symbols"] = tool_tree_sitter_symbols,
  ["nvime.git_log"] = tool_git_log,
  ["nvime.git_blame"] = tool_git_blame,
  ["nvime.test_run"] = tool_test_run,
  ["nvime.session_search"] = tool_session_search,
  ["nvime.session_recent"] = tool_session_recent,
  ["nvime.recent_diffs"] = tool_recent_diffs,
  ["nvime.verify_file"] = tool_verify_file,
}

local function jsonrpc_response(id, result)
  return { jsonrpc = "2.0", id = id, result = result }
end

local function jsonrpc_error(id, code, message)
  return { jsonrpc = "2.0", id = id, error = { code = code, message = message } }
end

local function send(message)
  if message == nil then
    return
  end
  local ok, encoded = pcall(vim.json.encode, message)
  if not ok then
    return
  end
  io.write(encoded)
  io.write("\n")
  io.flush()
end

local function handle(req)
  if type(req) ~= "table" or req.jsonrpc ~= "2.0" then
    if req and req.id ~= nil then
      return jsonrpc_error(req.id, -32600, "invalid request")
    end
    return nil
  end
  local method = req.method
  local params = req.params or {}
  local id = req.id
  local is_notification = id == nil

  if method == "initialize" then
    if is_notification then
      return nil
    end
    -- Only echo a version we actually implement; otherwise advertise the
    -- one we DO speak and let the client decide whether to downgrade.
    local requested = params.protocolVersion
    local protocol = (requested and SUPPORTED_PROTOCOL_VERSIONS[requested]) and requested or PROTOCOL_VERSION
    return jsonrpc_response(id, {
      protocolVersion = protocol,
      capabilities = { tools = { listChanged = false } },
      serverInfo = SERVER_INFO,
    })
  end
  if method == "notifications/initialized" or method == "initialized" then
    return nil
  end
  if is_notification then
    return nil
  end
  if method == "ping" then
    return jsonrpc_response(id, vim.empty_dict())
  end
  if method == "tools/list" then
    return jsonrpc_response(id, { tools = TOOLS })
  end
  if method == "tools/call" then
    local name = params.name
    local handler = TOOL_HANDLERS[name]
    if not handler then
      return jsonrpc_error(id, -32601, "unknown tool: " .. tostring(name))
    end
    local ok, result = pcall(handler, params.arguments or {})
    if not ok then
      return jsonrpc_response(id, err_result(result))
    end
    return jsonrpc_response(id, result)
  end
  if method == "shutdown" then
    return jsonrpc_response(id, vim.empty_dict())
  end
  return jsonrpc_error(id, -32601, "method not found: " .. tostring(method))
end

-- Process a single newline-terminated request line. Used in tests too.
function M.handle_line(line)
  if not line or line == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok then
    -- Spec forbids responding to malformed notifications. We can only
    -- emit a parse error when we successfully extracted an id, which by
    -- definition we did not — so silently drop.
    return nil
  end
  return handle(decoded)
end

local function read_loop()
  while true do
    local line = io.read("*l")
    if not line then
      break
    end
    if line ~= "" then
      local response = M.handle_line(line)
      if response then
        send(response)
      end
    end
    if line and line:match('"method"%s*:%s*"shutdown"') then
      break
    end
  end
end

-- Entry point. Spawned as a subprocess by claude (or any MCP-aware client).
function M.run()
  local ok = pcall(read_loop)
  if not ok then
    -- Best-effort: any unhandled error already aborted the loop; exit cleanly.
  end
  vim.cmd("qa!")
end

return M
