-- nvime.bigchange.triviality
--
-- Pure, side-effect-free classifier for the Big Change forced-comprehension
-- review. It decides whether a review block is SELF-EVIDENT — imports/requires,
-- documentation/markdown prose, comment-only edits, docstrings, or
-- version/config value bumps — and therefore needs no graded explanation. Such
-- blocks are auto-cleared by blocks.lua; everything else keeps the usual
-- grading bar. A docstring inherently restates the functional change it
-- documents, so editing one is never a substantive change on its own.
--
-- This module NEVER requires blocks.lua (which requires it): the caller passes
-- the already-resolved hunks via blocks.block_hunks(session, block).

local state = require("nvime.state")
local store = require("nvime.bigchange.store")

local M = {}

-- Default documentation globs (mirrors config.defaults.bigchange.trivial). Used
-- when the user has not overridden bigchange.trivial.doc_globs.
local DEFAULT_DOC_GLOBS = {
  "*.md",
  "*.markdown",
  "*.rst",
  "*.txt",
  "**/*.md",
  "**/*.markdown",
  "**/*.rst",
  "**/*.txt",
  "docs/**",
  "doc/**",
}

-- Built-in config/version file set (fixed, not user-overridable). A changed
-- line in one of these files counts as a self-evident value bump.
local CONFIG_GLOBS = {
  "**/version.lua",
  "VERSION",
  "**/VERSION",
  "version.txt",
  "*.toml",
  "**/*.toml",
  "*.ini",
  "**/*.ini",
  "*.cfg",
  "**/*.cfg",
  "*.conf",
  "**/*.conf",
  "*.yaml",
  "**/*.yaml",
  "*.yml",
  "**/*.yml",
  "package.json",
  "**/package.json",
}

-- Config/doc paths that LOOK like value files but can carry executable behavior
-- (CI workflows with `run:` steps, package manifests with install/postinstall
-- scripts, compose/Dockerfiles, docs that are actually .py/.sh). These are
-- excluded from the file-level doc/config auto-clear so their changes fall
-- through to per-line classification — a value/comment line still clears, but a
-- script/command line stays substantive instead of clearing by path alone.
local EXEC_CONFIG_GLOBS = {
  ".github/**",
  "**/.github/**",
  "package.json",
  "**/package.json",
  "Dockerfile",
  "**/Dockerfile",
  "**/Dockerfile.*",
  "**/*compose*.yml",
  "**/*compose*.yaml",
  "docs/**/*.py",
  "doc/**/*.py",
  "docs/**/*.sh",
  "doc/**/*.sh",
  "**/Makefile",
  "Makefile",
}

-- Comment prefix(es) by file extension.
local COMMENT_PREFIXES = {
  lua = { "--" },
  py = { "#" },
  sh = { "#" },
  bash = { "#" },
  zsh = { "#" },
  rb = { "#" },
  yaml = { "#" },
  yml = { "#" },
  toml = { "#" },
  ini = { "#" },
  cfg = { "#" },
  conf = { "#" },
  js = { "//" },
  ts = { "//" },
  jsx = { "//" },
  tsx = { "//" },
  go = { "//" },
  c = { "//" },
  cpp = { "//" },
  cc = { "//" },
  h = { "//" },
  hpp = { "//" },
  java = { "//" },
  rs = { "//" },
  zig = { "//" },
}

-- Extensions whose grammar uses C-style block comments; their comment lines may
-- begin with `/*`, `*`, or `*/` in addition to the line-comment prefix above.
local C_FAMILY = {
  js = true,
  ts = true,
  jsx = true,
  tsx = true,
  go = true,
  c = true,
  cpp = true,
  cc = true,
  h = true,
  hpp = true,
  java = true,
  rs = true,
  zig = true,
}

-- Import/require/use statement pattern(s) by file extension. `is_import` only
-- checks that a line BEGINS like an import; `has_exec_tail` then rejects a match
-- that also carries executable code (a `;`-compound, an invoked require), so
-- these can stay permissive without auto-clearing real code.
local IMPORT_PATTERNS = {
  py = { "^import%s", "^from%s+[%w%._]+%s+import%s" },
  -- `require` must be the real call/keyword, not an identifier that merely
  -- begins with those letters (`required_settings`, `require_init`): the
  -- frontier `%f[^%w_]` anchors the match to a word boundary after `require`.
  lua = { "^local%s+[%w_,%s]+=%s*require%f[^%w_]", "^require%s*%(" },
  -- `^import%s+["'{*%w]` excludes the space-form dynamic import `import (…)` (a
  -- Promise-returning call, not a static import). `^export%s*{` opens a
  -- multi-line re-export whose `from` clause sits on the closing line.
  js = { "^import%s+[\"'{*%w]", "^export%s+.*%sfrom%s", "^export%s*{", "=%s*require%s*%(" },
  ts = { "^import%s+[\"'{*%w]", "^export%s+.*%sfrom%s", "^export%s*{", "=%s*require%s*%(" },
  jsx = { "^import%s+[\"'{*%w]", "^export%s+.*%sfrom%s", "^export%s*{", "=%s*require%s*%(" },
  tsx = { "^import%s+[\"'{*%w]", "^export%s+.*%sfrom%s", "^export%s*{", "=%s*require%s*%(" },
  go = { "^import%s" },
  -- `pub use` / `pub(crate) use` re-exports are still self-evident imports.
  rs = { "^use%s", "^pub%s+use%s", "^pub%b()%s*use%s" },
  c = { "^#include" },
  cpp = { "^#include" },
  h = { "^#include" },
  java = { "^import%s" },
}

-- Triple-quoted docstring delimiters by file extension. Only languages whose
-- docstrings are bare string literals (not comments) need an entry — comment
-- style docs (Lua ---, JS /** */) are already covered by is_comment. Detection
-- is stateful: a changed line that BEGINS with one of these opens a docstring
-- region whose content is self-evident until the matching delimiter closes it.
local DOCSTRING_DELIMS = {
  py = { '"""', "'''" },
  pyi = { '"""', "'''" },
}

-- Optional Python string-literal prefixes (raw/bytes/format/unicode) allowed
-- before a docstring delimiter, so r"""...""" still reads as a docstring open.
local STR_PREFIX = "^[rRbBuUfF]?[rRbBuUfF]?"

-- ---------------------------------------------------------------------------
-- config accessors
-- ---------------------------------------------------------------------------
local function cfg()
  return ((state.config or {}).bigchange or {}).trivial or {}
end

local function enabled()
  return cfg().enabled ~= false
end

local function doc_globs()
  local g = cfg().doc_globs
  if type(g) == "table" then
    return g
  end
  return DEFAULT_DOC_GLOBS
end

-- Delegate to the shared glob matcher policy_rules.lua reuses, with a false
-- fallback if verify.lua is somehow unavailable.
local function path_matches_any(path, globs)
  local ok, verify = pcall(require, "nvime.verify")
  if ok and verify and type(verify._path_matches_any) == "function" then
    return verify._path_matches_any(path, globs)
  end
  return false
end

-- ---------------------------------------------------------------------------
-- classification helpers
-- ---------------------------------------------------------------------------
local function ext_of(file)
  if not file or file == "" then
    return nil
  end
  return file:lower():match("%.([%w]+)$")
end

local function is_comment(trimmed, file)
  local ext = ext_of(file)
  local prefixes = ext and COMMENT_PREFIXES[ext]
  if prefixes then
    for _, p in ipairs(prefixes) do
      if vim.startswith(trimmed, p) then
        return true
      end
    end
  end
  if ext and C_FAMILY[ext] then
    if vim.startswith(trimmed, "/*") or vim.startswith(trimmed, "*/") then
      return true
    end
    -- A leading `*` is only a block-comment continuation (javadoc/qdoc style)
    -- when it stands alone or is followed by whitespace or another `*`. A `*`
    -- glued to an identifier/operator is a pointer deref or multiply that begins
    -- a real statement (`*p = evil();`, `*self.count += 1`, `*out++ = *in++`),
    -- which must NOT be auto-cleared as a comment.
    if vim.startswith(trimmed, "*") then
      local after = trimmed:sub(2, 2)
      if after == "" or after == " " or after == "\t" or after == "*" or after == "/" then
        return true
      end
    end
  end
  return false
end

local function is_import(trimmed, file)
  local ext = ext_of(file)
  local patterns = ext and IMPORT_PATTERNS[ext]
  if not patterns then
    return false
  end
  for _, pat in ipairs(patterns) do
    if trimmed:match(pat) then
      return true
    end
  end
  return false
end

-- Reduce a line to its CODE: blank out string/char-literal spans and drop a
-- trailing line comment. Bracket counting and trailing-code detection run on
-- this, so a `(` inside a comment or a `;` inside a string can neither corrupt
-- the import-bracket depth nor hide executable code. Block comments are not
-- handled — an import line never opens one.
local function code_only(line, file)
  local markers = COMMENT_PREFIXES[ext_of(file)] or {}
  local out, i, n, quote = {}, 1, #line, nil
  while i <= n do
    local c = line:sub(i, i)
    if quote then
      if c == "\\" then
        i = i + 2 -- skip the escaped char so an escaped quote does not close early
      else
        if c == quote then
          quote = nil
        end
        i = i + 1
      end
    else
      local comment = false
      for _, m in ipairs(markers) do
        if line:sub(i, i + #m - 1) == m then
          comment = true
          break
        end
      end
      if comment then
        break
      elseif c == '"' or c == "'" or c == "`" then
        quote, i = c, i + 1
      else
        out[#out + 1], i = c, i + 1
      end
    end
  end
  return table.concat(out)
end

-- Net bracket delta on already-`code_only`-sanitized text: opening `(`/`{` minus
-- closing `)`/`}`. A multi-line import block (Python `from x import (…)`, Go
-- `import (…)`, JS/TS `import {…} from`, Rust `use a::{…}`) opens with a positive
-- delta and closes when the running depth returns to zero; its continuation
-- lines carry only symbol names and a bare closer.
local function net_brackets(code)
  local _, opens = code:gsub("[%({]", "")
  local _, closes = code:gsub("[%)}]", "")
  return opens - closes
end

-- True when sanitized `code` carries executable code beyond a self-contained
-- import: a compound statement after a top-level `;`, or a `require(...)` whose
-- result is immediately invoked / method-chained (`require("x").setup()`,
-- `require("x")(app)`). Such a line begins like an import but is NOT trivial.
local function has_exec_tail(code)
  local semi = code:find(";")
  while semi do
    if code:find("%S", semi + 1) then
      return true
    end
    semi = code:find(";", semi + 1)
  end
  local pos = code:find("require%s*%(")
  while pos do
    -- Bind `open` to a single value: as the trailing arg to find it would
    -- otherwise spill its second return into find's `plain` flag.
    local open = code:find("%(", pos)
    local _, close = code:find("%b()", open)
    if not close then
      break
    end
    -- A `.field`/`:method` chain (or none) followed by `(` is an invocation.
    if code:sub(close + 1):match("^[%.%w_:]*%s*%(") then
      return true
    end
    pos = code:find("require%s*%(", close + 1)
  end
  return false
end

-- When `trimmed` (a leading-trimmed line) begins a triple-quoted docstring for
-- `file`, return the matched delimiter and the number of times it occurs on the
-- line (>= 2 means the docstring also closes on this same line). Returns nil
-- when the line does not open a docstring. A line that merely contains a triple
-- quote mid-expression (e.g. `q = """..."""`) is NOT a docstring open: by
-- convention a docstring line starts with the delimiter.
local function docstring_open(trimmed, file)
  local delims = DOCSTRING_DELIMS[ext_of(file)]
  if not delims then
    return nil
  end
  local rest = (trimmed:gsub(STR_PREFIX, "", 1))
  for _, d in ipairs(delims) do
    if vim.startswith(rest, d) then
      local _, n = rest:gsub(vim.pesc(d), "")
      return d, n
    end
  end
  return nil
end

-- Classify a single changed line into a trivial kind, or nil when the line is
-- substantive (executable / meaningful code). doc and config are file-level:
-- ANY line in such a file is trivial.
function M._trivial_kind(text, file)
  -- An executable-capable config/doc file is classified per-line (below), never
  -- whole-file by path, so a `run:`/script/command line can't auto-clear.
  local exec_config = path_matches_any(file, EXEC_CONFIG_GLOBS)
  if not exec_config then
    if path_matches_any(file, doc_globs()) then
      return "doc"
    end
    if path_matches_any(file, CONFIG_GLOBS) then
      return "config"
    end
  end
  local trimmed = vim.trim(text or "")
  if trimmed == "" then
    return "blank"
  end
  if is_comment(trimmed, file) then
    return "comment"
  end
  -- An import prefix only counts when nothing executable rides on the same line
  -- (`import os; wipe()`, `local x = require("m").run()`).
  if is_import(trimmed, file) and not has_exec_tail(code_only(trimmed, file)) then
    return "import"
  end
  return nil
end

-- Iterate the add/del lines of a hunk list, calling fn(text). Returns whether
-- any changed line was seen.
local function each_changed(hunks, fn)
  local any = false
  for _, h in ipairs(hunks or {}) do
    for _, l in ipairs(h.lines or {}) do
      if l.kind == "add" or l.kind == "del" then
        any = true
        fn(l.text or "")
      end
    end
  end
  return any
end

-- Scan the changed lines IN ORDER, tracking triple-quoted docstring state and
-- multi-line import-bracket state so a multi-line docstring's interior prose or
-- a multi-line import's symbol list is recognised even though only the opening
-- line carries the delimiter / import keyword. Returns { kinds = set,
-- substantive = bool, any = bool } where `kinds` keys are trivial categories
-- (doc/config/comment/import/docstring/blank) seen across the block.
local function scan_changed(hunks, file)
  local kinds, substantive, any = {}, false, false
  -- Per-stream state (added vs deleted) because a hunk interleaves the old and
  -- new line versions; one shared state would let a new region's opening line
  -- read as the close of the deleted one. `ds_*` tracks an open triple-quoted
  -- docstring; `imp_*` tracks an open multi-line import bracket block.
  local streams = {
    add = { ds_open = false, ds_delim = nil, imp_open = false, imp_depth = 0 },
    del = { ds_open = false, ds_delim = nil, imp_open = false, imp_depth = 0 },
  }
  -- Open an import block when an import opener leaves an unbalanced bracket.
  local function open_block(st, code)
    local depth = net_brackets(code)
    if depth > 0 then
      st.imp_open, st.imp_depth = true, depth
    end
  end
  -- Advance an open block's depth by this line's brackets, closing at zero.
  local function advance(st, code)
    st.imp_depth = st.imp_depth + net_brackets(code)
    if st.imp_depth <= 0 then
      st.imp_open, st.imp_depth = false, 0
    end
  end
  for _, h in ipairs(hunks or {}) do
    -- Classify each hunk against ITS OWN file, not the (agent-declared) block
    -- file: an agent could group real .py/.go code into a block it mislabels
    -- "README.md" so every line reads as doc and auto-clears. h.file is the
    -- diff's real path; `file` is only a fallback.
    local hfile = h.file or file
    -- Import-bracket AND docstring state never span a hunk: each is contiguous
    -- source whose opener and closer share one hunk. Resetting per hunk stops a
    -- region whose closer fell outside the diff context from leaking into a
    -- later hunk and swallowing real code there.
    streams.add.imp_open, streams.add.imp_depth = false, 0
    streams.del.imp_open, streams.del.imp_depth = false, 0
    streams.add.ds_open, streams.add.ds_delim = false, nil
    streams.del.ds_open, streams.del.ds_delim = false, nil
    for _, l in ipairs(h.lines or {}) do
      local text = l.text or ""
      local trimmed = vim.trim(text)
      local code = code_only(trimmed, hfile)
      if l.kind == "ctx" then
        -- A context (unchanged) line moves import/docstring state in BOTH streams
        -- so a change nested inside an otherwise-unchanged region reads correctly,
        -- and — critically — a docstring whose CLOSING delimiter is a context line
        -- is closed here, so executable add-lines AFTER it are not swept up as
        -- docstring. Context never sets kinds / substantive / any.
        for _, st in pairs(streams) do
          if st.ds_open then
            if st.ds_delim and trimmed:find(vim.pesc(st.ds_delim)) then
              st.ds_open, st.ds_delim = false, nil
            end
          elseif st.imp_open then
            advance(st, code)
          elseif is_import(trimmed, hfile) and not has_exec_tail(code) then
            open_block(st, code)
          end
        end
      elseif l.kind == "add" or l.kind == "del" then
        any = true
        local st = streams[l.kind]
        if st.imp_open then
          -- Inside a multi-line import the lines are bare member names; a call
          -- `(`, an assignment `=`, or a trailing statement means real code rode
          -- in (a closer that also runs code, or an unbalanced opener swallowing
          -- the next statement), so the block ends and this line is substantive.
          if has_exec_tail(code) or code:find("[%(=]") then
            substantive = true
            st.imp_open, st.imp_depth = false, 0
          else
            kinds.import = true
            advance(st, code)
          end
        elseif st.ds_open then
          kinds.docstring = true
          if st.ds_delim and trimmed:find(vim.pesc(st.ds_delim)) then
            st.ds_open, st.ds_delim = false, nil
          end
        else
          local d, n = docstring_open(trimmed, hfile)
          if d then
            kinds.docstring = true
            if n < 2 then
              st.ds_open, st.ds_delim = true, d
            end
          else
            local k = M._trivial_kind(text, hfile)
            if k then
              kinds[k] = true
              -- An import opener with an unbalanced bracket starts a multi-line
              -- import block whose continuation lines follow until it balances.
              if k == "import" then
                open_block(st, code)
              end
            else
              substantive = true
            end
          end
        end
      end
    end
  end
  return { kinds = kinds, substantive = substantive, any = any }
end

-- True when ANY changed line is substantive (no trivial kind, not docstring).
function M._has_substantive_code(hunks, file)
  return scan_changed(hunks, file).substantive
end

-- The single pure category name when every changed line maps to ONE trivial
-- kind (blank lines may interleave freely), else nil. doc/config are file-level;
-- comments, imports, and docstrings allow interleaved blanks only.
function M._pure_category(hunks, file)
  local res = scan_changed(hunks, file)
  if not res.any or res.substantive then
    return nil
  end
  local CATEGORY = {
    doc = "docs",
    config = "config",
    import = "imports",
    comment = "comments",
    docstring = "docstrings",
  }
  local found
  for k in pairs(res.kinds) do
    if k ~= "blank" then
      if found then
        return nil -- more than one non-blank kind: not category-pure
      end
      found = k
    end
  end
  return found and CATEGORY[found] or nil
end

-- ---------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------

-- True only when the relaxation is active for this session: enabled AND
-- difficulty is easy/medium (not extreme, not vibe).
function M.applies(session)
  if not session or not enabled() then
    return false
  end
  if session.difficulty == "extreme" then
    return false
  end
  local d = store.DIFFICULTY[session.difficulty] or store.DIFFICULTY.medium
  return d.threshold ~= nil
end

-- Classify a block. `hunks` is blocks.block_hunks(session, block).
-- Returns { trivial = bool, category = string|nil, source = string|nil }.
function M.classify(session, block, hunks)
  if not M.applies(session) then
    return { trivial = false }
  end
  local file = block and block.file
  -- No changed lines → nothing to relax.
  local has_changed = each_changed(hunks, function() end)
  if not has_changed then
    return { trivial = false }
  end
  -- Heuristic floor: deterministic, category-pure.
  local cat = M._pure_category(hunks, file)
  if cat then
    return { trivial = true, category = cat, source = "heuristic" }
  end
  -- Agent path: broader (mixed trivial kinds), but guarded so no executable
  -- code line is ever auto-cleared.
  if block and block.agent_trivial == true and not M._has_substantive_code(hunks, file) then
    return { trivial = true, category = "mixed", source = "agent" }
  end
  return { trivial = false }
end

-- Test-only export.
M._path_matches_any = path_matches_any

return M
