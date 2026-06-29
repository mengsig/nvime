-- nvime.verify
--
-- Pre-accept verification lane. When a diff session is created, run cheap
-- deterministic checks against the *proposed* full file content — the state
-- the user would see if every pending block were accepted. Findings appear
-- in the diff banner; a parse error in the proposed content blocks `ga` /
-- `gA` (force with `gA!`).
--
-- Three families of check:
--   parse  : tree-sitter Parser:parse() on the proposed text. Any node with
--            has_error() flips severity:error and trips the accept gate.
--   lint   : configured external command matched by glob (ruff, shellcheck,
--            luacheck/selene, gofmt -e, zig ast-check, ...). Captured
--            stdout/stderr tolerantly parsed into findings. Advisory; does
--            not block accept by default.
--   type   : type checker (tsc, mypy, cargo check). Same shape; advisory.
--
-- Tools that are not on PATH are silently skipped. All external checks run
-- async via vim.system. The proposed content is written to a stable tempfile
-- under stdpath('cache')/nvime/verify/ so checks that need a real path (and
-- project-config resolution by directory walk) keep working.
--
-- session.verify shape:
--   {
--     status = "pending" | "ok" | "issues" | "error",
--     parse_error = boolean,    -- the gate signal
--     findings = { { kind, severity, message, line?, col?, source } ... },
--     summary = "ruff 3 issues · parse ok",
--     by_check = { [name] = { code, stdout_excerpt, count } },
--     started_at = <hrtime ms>,
--   }

local audit = require("nvime.audit")
local state = require("nvime.state")

local M = {}

local uv = vim.uv or vim.loop

local DEFAULT_TIMEOUT_MS = 8000
local MAX_FINDINGS_PER_CHECK = 50
local STDOUT_EXCERPT_BYTES = 800

local function cfg()
  return (state.config or {}).verify or {}
end

local function enabled()
  if state.disabled then
    return false
  end
  return cfg().enabled ~= false
end

local function parse_enabled()
  return cfg().treesitter_parse ~= false
end

local function block_on_parse_error()
  return cfg().block_on_parse_error ~= false
end

local function timeout_ms()
  return tonumber(cfg().timeout_ms) or DEFAULT_TIMEOUT_MS
end

local function notify(msg, level)
  vim.schedule(function()
    vim.notify("nvime verify: " .. msg, level or vim.log.levels.INFO)
  end)
end

-- Cache directory for proposed-content tempfiles. We reuse one path per
-- session id so a re-render after accept/reject can overwrite cheaply.
local function cache_dir()
  local dir = vim.fn.stdpath("cache") .. "/nvime/" .. "verify"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function tempfile_for(session)
  local base = vim.fn.fnamemodify(session.file or "buf", ":t")
  local sig = tostring(session.review_id or session.target_bufnr or uv.hrtime())
  return cache_dir() .. "/" .. sig .. "-" .. base
end

local function write_tempfile(path, lines)
  local fd, err = io.open(path, "w")
  if not fd then
    return false, err
  end
  fd:write(table.concat(lines or {}, "\n"))
  fd:write("\n")
  fd:close()
  return true
end

-- Glob → Lua pattern matcher tuned for filename extensions and dir prefixes.
-- The recommended config glob shapes are "*.py" and "**/migrations/**", which
-- this handler covers; full POSIX globs are not needed.
local function glob_to_pattern(glob)
  local pattern = "^"
  local i = 1
  while i <= #glob do
    local c = glob:sub(i, i)
    if c == "*" then
      if glob:sub(i + 1, i + 1) == "*" then
        pattern = pattern .. ".*"
        i = i + 2
        if glob:sub(i, i) == "/" then
          i = i + 1
        end
      else
        pattern = pattern .. "[^/]*"
        i = i + 1
      end
    elseif c == "?" then
      pattern = pattern .. "[^/]"
      i = i + 1
    elseif c:match("[%^%$%(%)%%%.%[%]%+%-]") then
      pattern = pattern .. "%" .. c
      i = i + 1
    else
      pattern = pattern .. c
      i = i + 1
    end
  end
  return pattern .. "$"
end

local function basename(path)
  return path:match("([^/]+)$") or path
end

local function path_matches_any(path, globs)
  if not path or not globs or #globs == 0 then
    return false
  end
  local base = basename(path)
  for _, glob in ipairs(globs) do
    local pattern = glob_to_pattern(glob)
    -- Globs without a slash match the basename (common case "*.py"); globs
    -- containing a slash match the full path.
    local target = glob:find("/", 1, true) and path or base
    if target:match(pattern) then
      return true
    end
  end
  return false
end

-- Built-in external checks. Each entry runs only when the binary is on PATH
-- and the file path matches at least one of `match`. `cmd(tempfile)` returns
-- the argv to spawn; `parse(stdout, stderr)` turns captured output into a
-- list of findings.
local BUILTIN_CHECKS = {
  {
    name = "ruff",
    kind = "lint",
    match = { "*.py" },
    cmd = function(tempfile)
      return { "ruff", "check", "--no-fix", "--output-format=concise", "--quiet", tempfile }
    end,
    parse = function(stdout)
      local findings = {}
      for line in (stdout or ""):gmatch("[^\r\n]+") do
        local file, l, c, msg = line:match("^([^:]+):(%d+):(%d+): (.+)$")
        if file and msg then
          findings[#findings + 1] = {
            severity = "warn",
            line = tonumber(l),
            col = tonumber(c),
            message = msg,
          }
        end
        if #findings >= MAX_FINDINGS_PER_CHECK then
          break
        end
      end
      return findings
    end,
  },
  {
    name = "shellcheck",
    kind = "lint",
    match = { "*.sh", "*.bash" },
    cmd = function(tempfile)
      return { "shellcheck", "--format=gcc", tempfile }
    end,
    parse = function(stdout)
      local findings = {}
      for line in (stdout or ""):gmatch("[^\r\n]+") do
        local _, l, c, sev, msg = line:match("^([^:]+):(%d+):(%d+): (%a+): (.+)$")
        if l then
          findings[#findings + 1] = {
            severity = sev and sev:lower() == "error" and "error" or "warn",
            line = tonumber(l),
            col = tonumber(c),
            message = msg,
          }
        end
        if #findings >= MAX_FINDINGS_PER_CHECK then
          break
        end
      end
      return findings
    end,
  },
  {
    name = "luacheck",
    kind = "lint",
    match = { "*.lua" },
    cmd = function(tempfile)
      return { "luacheck", "--no-color", "--formatter=plain", "--ranges", tempfile }
    end,
    parse = function(stdout)
      local findings = {}
      for line in (stdout or ""):gmatch("[^\r\n]+") do
        local l, c, msg = line:match(":(%d+):(%d+)[%-%d]*: (.+)$")
        if l then
          findings[#findings + 1] = {
            severity = "warn",
            line = tonumber(l),
            col = tonumber(c),
            message = msg,
          }
        end
        if #findings >= MAX_FINDINGS_PER_CHECK then
          break
        end
      end
      return findings
    end,
  },
  {
    name = "selene",
    kind = "lint",
    match = { "*.lua" },
    cmd = function(tempfile)
      return { "selene", "--display-style=quiet", "--no-summary", tempfile }
    end,
    parse = function(stdout, stderr)
      local findings = {}
      local combined = (stdout or "") .. "\n" .. (stderr or "")
      for line in combined:gmatch("[^\r\n]+") do
        -- The pattern has exactly two captures: severity word and message.
        -- Binding four locals left msg (capture 4) always nil, so the message
        -- below fell back to the raw `path:line:col:` line every time.
        local sev, msg = line:match("(%a+)%[[^%]]+%]: (.-)\n?$")
        local pl, pc = line:match(":(%d+):(%d+):")
        if pl then
          findings[#findings + 1] = {
            severity = sev and sev:lower() == "error" and "error" or "warn",
            line = tonumber(pl),
            col = tonumber(pc),
            message = msg or line,
          }
        end
        if #findings >= MAX_FINDINGS_PER_CHECK then
          break
        end
      end
      return findings
    end,
  },
  {
    name = "gofmt",
    kind = "parse",
    match = { "*.go" },
    cmd = function(tempfile)
      return { "gofmt", "-e", "-l", tempfile }
    end,
    parse = function(_, stderr)
      local findings = {}
      for line in (stderr or ""):gmatch("[^\r\n]+") do
        local l, c, msg = line:match(":(%d+):(%d+): (.+)$")
        if l then
          findings[#findings + 1] = {
            severity = "error",
            line = tonumber(l),
            col = tonumber(c),
            message = msg,
          }
        end
        if #findings >= MAX_FINDINGS_PER_CHECK then
          break
        end
      end
      return findings
    end,
  },
  {
    name = "zig-ast",
    kind = "parse",
    match = { "*.zig" },
    cmd = function(tempfile)
      return { "zig", "ast-check", tempfile }
    end,
    parse = function(_, stderr)
      local findings = {}
      for line in (stderr or ""):gmatch("[^\r\n]+") do
        local l, c, msg = line:match(":(%d+):(%d+): error: (.+)$")
        if l then
          findings[#findings + 1] = {
            severity = "error",
            line = tonumber(l),
            col = tonumber(c),
            message = msg,
          }
        end
        if #findings >= MAX_FINDINGS_PER_CHECK then
          break
        end
      end
      return findings
    end,
  },
  {
    name = "mypy",
    kind = "type",
    match = { "*.py" },
    cmd = function(tempfile)
      return { "mypy", "--no-color-output", "--no-error-summary", "--hide-error-context", tempfile }
    end,
    parse = function(stdout)
      local findings = {}
      for line in (stdout or ""):gmatch("[^\r\n]+") do
        local l, sev, msg = line:match(":(%d+): (%a+): (.+)$")
        if l then
          findings[#findings + 1] = {
            severity = sev and sev:lower() == "error" and "error" or "warn",
            line = tonumber(l),
            message = msg,
          }
        end
        if #findings >= MAX_FINDINGS_PER_CHECK then
          break
        end
      end
      return findings
    end,
  },
}

local function user_checks()
  local out = {}
  local checks = cfg().checks or {}
  for name, entry in pairs(checks) do
    if type(entry) == "table" and (entry.cmd or entry.command) then
      out[#out + 1] = vim.tbl_extend("force", { name = name }, entry)
    end
  end
  return out
end

local function resolve_checks(path)
  local out = {}
  if cfg().external_checks == false then
    return out
  end
  if not path or path == "" then
    return out
  end
  for _, entry in ipairs(BUILTIN_CHECKS) do
    if path_matches_any(path, entry.match) then
      local bin = entry.cmd("__probe__")[1]
      if bin and vim.fn.executable(bin) == 1 then
        out[#out + 1] = entry
      end
    end
  end
  for _, entry in ipairs(user_checks()) do
    if path_matches_any(path, entry.match or {}) then
      out[#out + 1] = entry
    end
  end
  return out
end

-- Map a file path to a tree-sitter language when the buffer's filetype is
-- not available (MCP entry point). Uses :filetype.match when present, falls
-- back to a short extension table covering the languages whose external
-- checks we ship.
local EXT_TO_LANG = {
  py = "python",
  pyi = "python",
  ts = "typescript",
  tsx = "tsx",
  js = "javascript",
  jsx = "javascript",
  mjs = "javascript",
  cjs = "javascript",
  lua = "lua",
  go = "go",
  rs = "rust",
  zig = "zig",
  sh = "bash",
  bash = "bash",
  c = "c",
  h = "c",
  cpp = "cpp",
  hpp = "cpp",
  java = "java",
  rb = "ruby",
  json = "json",
  yaml = "yaml",
  yml = "yaml",
  toml = "toml",
  md = "markdown",
}

local function lang_from_path(path)
  if not path or path == "" then
    return nil
  end
  if vim.filetype and vim.filetype.match then
    local ok, ft = pcall(vim.filetype.match, { filename = path })
    if ok and ft and ft ~= "" then
      return ft
    end
  end
  local ext = path:lower():match("%.([%w]+)$")
  return ext and EXT_TO_LANG[ext] or nil
end

-- Languages whose tree-sitter grammars routinely surface ERROR nodes on
-- syntactically valid input (markdown around code fences, html in
-- mixed-content) — surfacing those as a hard parse gate produces too many
-- false positives, so we skip parse on these. Lint/type checks still run.
local LOOSE_PARSE_LANGUAGES = {
  markdown = true,
  markdown_inline = true,
  html = true,
  htmldjango = true,
  vimdoc = true,
  text = true,
  ["text/plain"] = true,
}

-- Treesitter parse check: pulls the buffer's filetype parser, parses the
-- proposed content as one shot, walks every tree's root for `has_error`
-- nodes. Returns { ok = bool, findings = {...} }.
local function treesitter_parse(session, lines)
  if not parse_enabled() then
    return { ok = true, findings = {} }
  end
  local lang = nil
  local bufnr = session.target_bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    local ft = vim.bo[bufnr].filetype
    if ft and ft ~= "" then
      lang = ft
    end
  end
  if not lang then
    -- No buffer (MCP entry point) — derive language from the path's
    -- extension/filetype-match so tree-sitter parse still runs.
    lang = lang_from_path(session.file)
  end
  if lang then
    local ok_resolve, lang_mod = pcall(require, "vim.treesitter.language")
    if ok_resolve and lang_mod and type(lang_mod.get_lang) == "function" then
      lang = lang_mod.get_lang(lang) or lang
    end
  end
  if not lang then
    return { ok = true, findings = {}, skipped = true }
  end
  if LOOSE_PARSE_LANGUAGES[lang] then
    return { ok = true, findings = {}, skipped = true }
  end
  local body = table.concat(lines or {}, "\n")
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, body, lang)
  if not ok_parser or not parser then
    return { ok = true, findings = {}, skipped = true }
  end
  local ok_parse, trees = pcall(function()
    return parser:parse()
  end)
  if not ok_parse or type(trees) ~= "table" then
    return { ok = true, findings = {}, skipped = true }
  end
  local findings = {}
  for _, tree in ipairs(trees) do
    local root = tree:root()
    if root and root.has_error and root:has_error() then
      -- Walk to surface a useful error location rather than just root.
      local stack = { root }
      while #stack > 0 do
        local node = table.remove(stack)
        if node:has_error() then
          local has_child_with_error = false
          for child in node:iter_children() do
            if child:has_error() then
              stack[#stack + 1] = child
              has_child_with_error = true
            end
          end
          local is_error_leaf = node:type() == "ERROR" or not has_child_with_error
          if is_error_leaf then
            local start_row, start_col = node:start()
            findings[#findings + 1] = {
              severity = "error",
              line = start_row + 1,
              col = start_col + 1,
              message = "tree-sitter parse error",
              source = "parse",
            }
            if #findings >= 5 then
              break
            end
          end
        end
      end
    end
  end
  return { ok = #findings == 0, findings = findings }
end

local function summarize(verify)
  if not verify then
    return ""
  end
  local parts = {}
  if verify.parse_error then
    parts[#parts + 1] = "parse error"
  end
  local total = 0
  for _, check in pairs(verify.by_check or {}) do
    total = total + (check.count or 0)
  end
  if total > 0 then
    parts[#parts + 1] = string.format("%d findings", total)
  end
  if verify.status == "ok" and #parts == 0 then
    return "ok"
  end
  if #parts == 0 then
    return verify.status or ""
  end
  return table.concat(parts, " · ")
end

local function refresh_session(session)
  local ok, diff = pcall(require, "nvime.diff")
  if ok and diff and type(diff.refresh_session) == "function" then
    pcall(diff.refresh_session, session)
  end
end

-- Signature of the proposed content verify last ran against. Verify is
-- otherwise idempotent (runs once at activation), but after a partial accept
-- OR reject the proposed content changes, so a stale parse gate could reflect
-- lines that will never exist. We key the cached result on the target buffer's
-- changedtick PLUS each block's resolution status (a reject changes the
-- proposed text without bumping the buffer's changedtick) and recompute when
-- either moves — mirroring risk.score's changedtick guard. See M.refresh.
local function content_signature(session)
  local parts = {}
  if session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr) then
    parts[#parts + 1] = tostring(vim.api.nvim_buf_get_changedtick(session.target_bufnr))
  end
  for _, block in ipairs(session.blocks or {}) do
    parts[#parts + 1] = tostring(block.id) .. ":" .. tostring(block.status)
  end
  if #parts == 0 then
    return "static"
  end
  return table.concat(parts, "|")
end

-- Sorted, de-duplicated list of findings that carry a location, as
-- { line, col, severity, message, source }. Used for ]v / [v navigation and
-- the quickfix list. parse-gate findings are included (the failing node is
-- the most actionable location of all).
local function finding_locations(session)
  local v = session and session.verify
  if not v then
    return {}
  end
  local out = {}
  local seen = {}
  for _, f in ipairs(v.findings or {}) do
    local line = tonumber(f.line)
    if line then
      local key = string.format("%d:%d:%s", line, tonumber(f.col) or 0, tostring(f.source))
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = {
          line = line,
          col = tonumber(f.col) or 1,
          severity = f.severity or "warn",
          message = f.message or "",
          source = f.source or "?",
        }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.line == b.line then
      return a.col < b.col
    end
    return a.line < b.line
  end)
  return out
end

-- Push located findings into a dedicated quickfix list so the reviewer can
-- jump to each one (the list is replaced, not opened — see verify.quickfix).
-- Entries point at the target buffer so locations track the live file; finding
-- lines are in *proposed* coordinates, so remap each into target coordinates
-- (the proposed/live file diverge while blocks are pending).
local function populate_quickfix(session)
  if cfg().quickfix == false then
    return
  end
  if not (session and session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr)) then
    return
  end
  local locs = finding_locations(session)
  if #locs == 0 then
    return
  end
  local map_line
  local ok_diff, diff = pcall(require, "nvime.diff")
  if ok_diff and diff and type(diff.map_proposed_line) == "function" then
    map_line = function(line)
      local ok, mapped = pcall(diff.map_proposed_line, session, line)
      if ok and type(mapped) == "number" then
        return mapped
      end
      return line
    end
  end
  local items = {}
  for _, loc in ipairs(locs) do
    items[#items + 1] = {
      bufnr = session.target_bufnr,
      lnum = map_line and map_line(loc.line) or loc.line,
      col = loc.col,
      type = (loc.severity == "error") and "E" or "W",
      text = string.format("[%s] %s", loc.source, loc.message),
    }
  end
  pcall(vim.fn.setqflist, {}, "r", {
    title = "nvime verify: " .. vim.fn.fnamemodify(session.file or "", ":t"),
    items = items,
  })
end

-- Run one external check. Returns immediately; on_finish is called with the
-- check result table on the main thread.
local function run_check(entry, tempfile, on_finish)
  local args = entry.cmd and entry.cmd(tempfile) or (entry.command and { entry.command, tempfile })
  if not args or not args[1] then
    on_finish({ name = entry.name, code = 0, findings = {} })
    return
  end
  local stdout_chunks = {}
  local stderr_chunks = {}
  local spawn_ok = pcall(vim.system, args, {
    text = true,
    timeout = timeout_ms(),
    stdout = function(_, data)
      if data then
        stdout_chunks[#stdout_chunks + 1] = data
      end
    end,
    stderr = function(_, data)
      if data then
        stderr_chunks[#stderr_chunks + 1] = data
      end
    end,
  }, function(out)
    local stdout = table.concat(stdout_chunks)
    local stderr = table.concat(stderr_chunks)
    local findings = {}
    if entry.parse then
      local ok, parsed = pcall(entry.parse, stdout, stderr)
      if ok and type(parsed) == "table" then
        findings = parsed
      end
    end
    for _, finding in ipairs(findings) do
      finding.source = finding.source or entry.name
      finding.kind = finding.kind or entry.kind or "lint"
    end
    local excerpt = (stdout ~= "" and stdout) or stderr or ""
    if #excerpt > STDOUT_EXCERPT_BYTES then
      excerpt = excerpt:sub(1, STDOUT_EXCERPT_BYTES - 3) .. "..."
    end
    vim.schedule(function()
      on_finish({
        name = entry.name,
        kind = entry.kind or "lint",
        code = out.code or 0,
        findings = findings,
        excerpt = excerpt,
      })
    end)
  end)
  -- Built-in checks are skipped when their binary is absent (resolve_checks
  -- probes vim.fn.executable), but user checks are not probed, and vim.system
  -- throws synchronously on a missing binary. Without this guard that throw
  -- escapes M.start's loop: `pending` never reaches 0, finalize never runs,
  -- and verification hangs. Treat a spawn failure as a skipped check.
  if not spawn_ok then
    vim.schedule(function()
      on_finish({ name = entry.name, kind = entry.kind or "lint", code = 0, findings = {}, excerpt = "" })
    end)
  end
end

-- Public: start verification for a freshly created diff session. Idempotent:
-- if a session already has session.verify set it returns the existing state.
function M.start(session)
  if not enabled() then
    return nil
  end
  if not session or not session.target_bufnr then
    return nil
  end
  local signature = content_signature(session)
  if session.verify and session.verify.status ~= nil and session.verify_signature == signature then
    return session.verify
  end

  local proposed
  local ok_diff, diff = pcall(require, "nvime.diff")
  if ok_diff and diff and type(diff._proposed_lines) == "function" then
    local ok, lines = pcall(diff._proposed_lines, session)
    if ok and type(lines) == "table" then
      proposed = lines
    end
  end
  if not proposed and session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr) then
    proposed = vim.api.nvim_buf_get_lines(session.target_bufnr, 0, -1, false)
  end

  local parse_result = treesitter_parse(session, proposed or {})
  -- Only treat a parse error as a regression to gate on if the *original*
  -- file content parsed cleanly. This lets synthetic / placeholder content
  -- (test buffers, scratch text) pass through without forcing gA!.
  local proposed_failed = not parse_result.ok and not parse_result.skipped
  local original_failed = false
  if proposed_failed then
    local original_parse = treesitter_parse(session, session.original_lines or {})
    original_failed = not original_parse.ok and not original_parse.skipped
  end
  session.verify = {
    status = "pending",
    findings = {},
    by_check = {},
    parse_error = proposed_failed and not original_failed,
    parse_regression_only = true,
    started_at = math.floor(uv.hrtime() / 1e6),
  }
  session.verify_signature = signature
  session.verify_run = (session.verify_run or 0) + 1
  local run_id = session.verify_run
  for _, finding in ipairs(parse_result.findings) do
    finding.source = finding.source or "parse"
    finding.kind = "parse"
    session.verify.findings[#session.verify.findings + 1] = finding
  end
  session.verify.by_check.parse = {
    code = parse_result.ok and 0 or 1,
    count = #parse_result.findings,
  }

  audit.write({
    event = "verify_start",
    file = session.file,
    parse_error = session.verify.parse_error,
  })

  local checks = resolve_checks(session.file)
  if #checks == 0 then
    session.verify.status = session.verify.parse_error and "error" or "ok"
    session.verify.summary = summarize(session.verify)
    audit.write({
      event = "verify_exit",
      file = session.file,
      parse_error = session.verify.parse_error,
      summary = session.verify.summary,
    })
    populate_quickfix(session)
    refresh_session(session)
    return session.verify
  end

  local tempfile = tempfile_for(session)
  local wrote, write_err = write_tempfile(tempfile, proposed or {})
  if not wrote then
    session.verify.status = session.verify.parse_error and "error" or "ok"
    session.verify.summary = summarize(session.verify) .. " (write failed)"
    notify("could not write tempfile: " .. tostring(write_err), vim.log.levels.WARN)
    refresh_session(session)
    return session.verify
  end

  local pending = #checks
  local function finalize()
    if session.verify_run ~= run_id then
      return
    end
    if session.verify.parse_error then
      session.verify.status = "error"
    else
      local total = 0
      for _, c in pairs(session.verify.by_check) do
        total = total + (c.count or 0)
      end
      session.verify.status = (total > 0) and "issues" or "ok"
    end
    session.verify.summary = summarize(session.verify)
    audit.write({
      event = "verify_exit",
      file = session.file,
      parse_error = session.verify.parse_error,
      summary = session.verify.summary,
    })
    populate_quickfix(session)
    refresh_session(session)
  end

  refresh_session(session) -- show parse result before externals land

  for _, entry in ipairs(checks) do
    run_check(entry, tempfile, function(result)
      if session.verify_run ~= run_id then
        return
      end
      session.verify.by_check[result.name] = {
        code = result.code,
        count = #result.findings,
        excerpt = result.excerpt,
        kind = result.kind,
      }
      for _, finding in ipairs(result.findings) do
        session.verify.findings[#session.verify.findings + 1] = finding
      end
      pending = pending - 1
      if pending <= 0 then
        finalize()
      else
        refresh_session(session)
      end
    end)
  end

  return session.verify
end

-- Public: should accept be gated? Returns (block: bool, reason: string?).
function M.should_block_accept(session)
  if not enabled() then
    return false, nil
  end
  if not block_on_parse_error() then
    return false, nil
  end
  local v = session and session.verify
  if not v then
    return false, nil
  end
  if v.parse_error then
    return true, "proposed file has tree-sitter parse error; use gA!/:NvimeAccept! to force"
  end
  return false, nil
end

-- Public: recompute verify after the proposed content changes (e.g. a partial
-- accept/reject). No-op when the changedtick+status signature is unchanged, so
-- it is cheap to call on every accept/reject. Returns the (possibly refreshed)
-- state.
function M.refresh(session)
  if not enabled() or not session or not session.target_bufnr then
    return session and session.verify or nil
  end
  if session.verify and session.verify_signature == content_signature(session) then
    return session.verify
  end
  return M.start(session)
end

-- Public: did an external lint/type check report an *error*-severity finding
-- (as opposed to the tree-sitter parse gate, which has its own signal)?
-- Returns (has_error: bool, detail: string?) where detail names the source,
-- e.g. "shellcheck". Drives diff.accept_policy.verify_tool_error. External
-- checks run async: until they complete this returns false even if a tool would
-- flag an error, so a "block" policy on verify_tool_error is not a hard
-- guarantee during the in-flight window before checks finish.
function M.has_tool_error(session)
  local v = session and session.verify
  if not v then
    return false, nil
  end
  for _, f in ipairs(v.findings or {}) do
    if f.severity == "error" and (f.source or "parse") ~= "parse" then
      return true, f.source
    end
  end
  return false, nil
end

-- Public: located findings for navigation (sorted, de-duplicated). Each entry
-- is { line, col, severity, message, source }.
function M.findings(session)
  return finding_locations(session)
end

-- Public: re-push the quickfix list for a session (used after a refresh so the
-- jump targets stay aligned with the current findings).
function M.fill_quickfix(session)
  populate_quickfix(session)
end

-- Collapsed per-tool breakdown of verify findings, e.g.
-- "    ruff 2 (E501) · shellcheck 1". Groups findings by source (skipping the
-- parse gate, which has its own row), takes a representative leading rule code
-- per source, caps at 3 tools. Returns nil when there is nothing to show.
local function per_tool_summary(v)
  local counts = {}
  local codes = {}
  local order = {}
  for _, f in ipairs((v and v.findings) or {}) do
    local src = f.source or "?"
    if src ~= "parse" then
      if counts[src] == nil then
        counts[src] = 0
        order[#order + 1] = src
      end
      counts[src] = counts[src] + 1
      if not codes[src] and type(f.message) == "string" then
        codes[src] = f.message:match("^%s*([A-Z]+%d+)")
      end
    end
  end
  if #order == 0 then
    return nil
  end
  table.sort(order, function(a, b)
    return counts[a] > counts[b]
  end)
  local rendered = {}
  for i = 1, math.min(3, #order) do
    local src = order[i]
    if codes[src] then
      rendered[#rendered + 1] = string.format("%s %d (%s)", src, counts[src], codes[src])
    else
      rendered[#rendered + 1] = string.format("%s %d", src, counts[src])
    end
  end
  if #order > 3 then
    rendered[#rendered + 1] = string.format("(+%d more)", #order - 3)
  end
  return "    " .. table.concat(rendered, " · ")
end

-- Public: render rows for the diff banner. Returns a list of
-- { text, highlight }, ready for virt_lines.
function M.banner_rows(session, icon_fn)
  local v = session and session.verify
  if not v then
    return {}
  end
  local rows = {}
  local function icon(name)
    return icon_fn and icon_fn(name) or ""
  end
  if v.status == "pending" then
    rows[#rows + 1] = { "  " .. icon("pending") .. " verify pending…", "NvimeMuted" }
    return rows
  end
  local label
  local hl
  if v.parse_error then
    label = icon("warning") .. " verify parse error (gA! to force)"
    hl = "NvimeError"
  elseif v.status == "issues" then
    label = icon("warning") .. " verify " .. (v.summary or "issues")
    hl = "NvimeStatusWarn"
  else
    label = icon("review") .. " verify " .. (v.summary or "ok")
    hl = "NvimeStatusSuccess"
  end
  rows[#rows + 1] = { "  " .. label, hl }
  if cfg().detail_in_banner and v.status == "issues" then
    local detail = per_tool_summary(v)
    if detail then
      rows[#rows + 1] = { detail, "NvimeMuted" }
    end
  end
  return rows
end

-- Public: run verify on arbitrary path + content (used by MCP tool). Returns
-- synchronously for tree-sitter parse; external checks run if `wait_ms` > 0.
function M.verify_path(path, content, opts)
  opts = opts or {}
  if not enabled() then
    return { status = "disabled", findings = {}, by_check = {} }
  end
  local lines
  if type(content) == "string" and content ~= "" then
    lines = vim.split(content, "\n", { plain = true })
  elseif vim.fn.filereadable(path) == 1 then
    lines = vim.fn.readfile(path)
  else
    return { status = "error", findings = {}, by_check = {}, error = "no readable path or content" }
  end
  local session = {
    file = path,
    target_bufnr = nil,
  }
  local parse_result = treesitter_parse(session, lines)
  local result = {
    status = parse_result.ok and "ok" or "error",
    parse_error = not parse_result.ok,
    findings = vim.deepcopy(parse_result.findings),
    by_check = { parse = { code = parse_result.ok and 0 or 1, count = #parse_result.findings } },
  }
  for _, finding in ipairs(result.findings) do
    finding.source = "parse"
    finding.kind = "parse"
  end
  local checks = resolve_checks(path)
  if #checks == 0 then
    return result
  end
  local tempfile = cache_dir() .. "/probe-" .. vim.fn.fnamemodify(path or "buf", ":t")
  local wrote = write_tempfile(tempfile, lines)
  if not wrote then
    return result
  end
  local wait_ms = tonumber(opts.wait_ms) or 0
  if wait_ms <= 0 then
    return result
  end
  -- Run synchronously by spawning each check and waiting.
  for _, entry in ipairs(checks) do
    local args = entry.cmd and entry.cmd(tempfile) or (entry.command and { entry.command, tempfile })
    if args and args[1] and vim.fn.executable(args[1]) == 1 then
      local ok, sys = pcall(vim.system, args, { text = true, timeout = math.min(timeout_ms(), wait_ms) })
      if ok and sys then
        local out = sys:wait()
        local findings = {}
        if entry.parse then
          local ok_parse, parsed = pcall(entry.parse, out.stdout or "", out.stderr or "")
          if ok_parse and type(parsed) == "table" then
            findings = parsed
          end
        end
        for _, finding in ipairs(findings) do
          finding.source = entry.name
          finding.kind = finding.kind or entry.kind or "lint"
          result.findings[#result.findings + 1] = finding
        end
        result.by_check[entry.name] = {
          code = out.code or 0,
          count = #findings,
          kind = entry.kind,
        }
      end
    end
  end
  if not result.parse_error then
    local total = 0
    for _, c in pairs(result.by_check) do
      total = total + (c.count or 0)
    end
    result.status = (total > 0) and "issues" or "ok"
  end
  return result
end

-- Test-only export.
M._builtin_checks = BUILTIN_CHECKS
M._glob_to_pattern = glob_to_pattern
M._path_matches_any = path_matches_any

return M
