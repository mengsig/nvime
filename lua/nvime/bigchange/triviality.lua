-- nvime.bigchange.triviality
--
-- Pure, side-effect-free classifier for the Big Change forced-comprehension
-- review. It decides whether a review block is SELF-EVIDENT — imports/requires,
-- documentation/markdown prose, comment-only edits, or version/config value
-- bumps — and therefore needs no graded explanation. Such blocks are
-- auto-cleared by blocks.lua; everything else keeps the usual grading bar.
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

-- Import/require/use statement pattern(s) by file extension.
local IMPORT_PATTERNS = {
  py = { "^import%s", "^from%s+[%w%._]+%s+import%s" },
  lua = { "^local%s+[%w_,%s]+=%s*require", "^require%s*%(" },
  js = { "^import%s", "^export%s+.*%sfrom%s", "=%s*require%s*%(" },
  ts = { "^import%s", "^export%s+.*%sfrom%s", "=%s*require%s*%(" },
  tsx = { "^import%s", "^export%s+.*%sfrom%s", "=%s*require%s*%(" },
  go = { "^import%s" },
  rs = { "^use%s" },
  c = { "^#include" },
  cpp = { "^#include" },
  h = { "^#include" },
  java = { "^import%s" },
}

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
    if vim.startswith(trimmed, "/*") or vim.startswith(trimmed, "*/") or vim.startswith(trimmed, "*") then
      return true
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

-- Classify a single changed line into a trivial kind, or nil when the line is
-- substantive (executable / meaningful code). doc and config are file-level:
-- ANY line in such a file is trivial.
function M._trivial_kind(text, file)
  if path_matches_any(file, doc_globs()) then
    return "doc"
  end
  if path_matches_any(file, CONFIG_GLOBS) then
    return "config"
  end
  local trimmed = vim.trim(text or "")
  if trimmed == "" then
    return "blank"
  end
  if is_comment(trimmed, file) then
    return "comment"
  end
  if is_import(trimmed, file) then
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

-- True when ANY changed line is substantive (trivial_kind == nil).
function M._has_substantive_code(hunks, file)
  local substantive = false
  each_changed(hunks, function(text)
    if M._trivial_kind(text, file) == nil then
      substantive = true
    end
  end)
  return substantive
end

-- The single pure category name when every changed line maps to it, else nil.
-- docs/config require the file to match their globs; imports/comments allow
-- interleaved blank lines.
function M._pure_category(hunks, file)
  local kinds = {}
  local any = each_changed(hunks, function(text)
    local k = M._trivial_kind(text, file)
    if k then
      kinds[k] = true
    else
      kinds.__substantive = true
    end
  end)
  if not any or kinds.__substantive then
    return nil
  end
  -- doc / config are file-level: every line maps to the one kind.
  if kinds.doc and not (kinds.config or kinds.comment or kinds.import) then
    return "docs"
  end
  if kinds.config and not (kinds.doc or kinds.comment or kinds.import) then
    return "config"
  end
  if kinds.import and not (kinds.doc or kinds.config or kinds.comment) then
    -- imports + interleaved blanks only.
    return "imports"
  end
  if kinds.comment and not (kinds.doc or kinds.config or kinds.import) then
    -- comments + interleaved blanks only.
    return "comments"
  end
  return nil
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
