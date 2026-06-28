-- nvime.intent
--
-- Local intent linter. Refuses or warns on vague prompts BEFORE the model
-- sees them. A vague intent ("clean this up", "fix bugs") wastes a turn
-- and tends to produce speculative edits — exactly the class of behavior
-- nvime is trying to make impossible. This module is the cheap, local
-- counterpart to the existing `looks_like_question` reroute in edit.lua.
--
-- The default classifier is pure heuristic:
--   - words below intent.min_words count as vague
--   - intents whose only verbs are vague ("clean", "improve", "polish")
--     and never name a concrete change verb count as vague
--   - intents that name only abstract objects ("this", "it", "stuff")
--     without a noun/file/symbol hint count as questionable
--
-- The optional `intent.classifier = "model"` mode can route to a cheap
-- model via the existing critic lane shape; deferred until a user opts in.
-- For now the heuristic is enough to catch the obvious failures.
--
-- Output:
--   { verdict = "ok" | "vague" | "questionable", reason, suggestions = {} }

local state = require("nvime.state")

local M = {}

local DEFAULT_MIN_WORDS = 4
local DEFAULT_MODEL_TIMEOUT_MS = 5000

-- Cache classifier verdicts on disk so the same prompt doesn't re-hit the
-- model on every call. djb2 hash on the trimmed intent.
local function djb2(text)
  local h = 5381
  for i = 1, #text do
    h = ((h * 33) + text:byte(i)) % 0xFFFFFFFF
  end
  return string.format("%08x", h)
end

local function cache_path()
  local ok, git = pcall(require, "nvime.git")
  if not ok then
    return vim.fn.stdpath("cache") .. "/nvime/intent-cache.json"
  end
  local root = git.root((vim.uv or vim.loop).cwd())
  if root then
    return root .. "/.nvime/intent-cache.json"
  end
  return vim.fn.stdpath("cache") .. "/nvime/intent-cache.json"
end

local function read_cache()
  local path = cache_path()
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or not raw or #raw == 0 then
    return {}
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not decoded_ok or type(decoded) ~= "table" then
    return {}
  end
  return decoded
end

local function write_cache(cache)
  local path = cache_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "w")
  if not fd then
    return false, err
  end
  fd:write(vim.json.encode(cache))
  fd:close()
  return true
end

local IMPERATIVE_VERBS = {
  add = true,
  remove = true,
  delete = true,
  rename = true,
  replace = true,
  implement = true,
  update = true,
  fix = true,
  refactor = true,
  extract = true,
  inline = true,
  move = true,
  write = true,
  create = true,
  change = true,
  modify = true,
  convert = true,
  ensure = true,
  validate = true,
  parse = true,
  ["return"] = true,
  handle = true,
  log = true,
  raise = true,
  throw = true,
  reject = true,
  accept = true,
  guard = true,
  cache = true,
  memoize = true,
  inject = true,
  emit = true,
  expose = true,
  hide = true,
  document = true,
  test = true,
  assert = true,
  format = true,
  sort = true,
  normalize = true,
  serialize = true,
  deserialize = true,
  encode = true,
  decode = true,
  split = true,
  join = true,
  trim = true,
  escape = true,
  unescape = true,
}

local VAGUE_VERBS = {
  clean = true,
  improve = true,
  polish = true,
  enhance = true,
  optimize = true,
  beautify = true,
  tidy = true,
}

local VAGUE_PHRASES = {
  "fix bugs",
  "fix the bugs",
  "fix any bugs",
  "fix issues",
  "clean up",
  "clean this up",
  "make better",
  "make it better",
  "look at",
  "look into",
  "have a look",
  "make nicer",
  "polish this",
  "improve this",
  "improve the code",
  "do whatever",
  "whatever you think",
}

local ABSTRACT_OBJECTS = {
  it = true,
  this = true,
  that = true,
  these = true,
  those = true,
  stuff = true,
  things = true,
  thing = true,
  code = true, -- "the code" without naming what
}

local function cfg()
  return (state.config or {}).intent or {}
end

local function enabled()
  return cfg().enabled ~= false
end

local function min_words()
  return tonumber(cfg().min_words) or DEFAULT_MIN_WORDS
end

local function lower_words(text)
  if type(text) ~= "string" then
    return {}
  end
  local out = {}
  for word in text:lower():gmatch("[%w_]+") do
    out[#out + 1] = word
  end
  return out
end

local function contains_any_phrase(text, phrases)
  local lower = text:lower()
  for _, phrase in ipairs(phrases) do
    if lower:find(phrase, 1, true) then
      return phrase
    end
  end
  return nil
end

local function looks_concrete(words)
  -- An intent looks concrete when it names at least one imperative verb
  -- AND at least one non-abstract object word. This keeps both
  -- "fix it" (verb yes, object abstract) and "users.py is wrong" (no
  -- imperative verb) flagged.
  local has_verb = false
  local concrete_object = false
  for _, word in ipairs(words) do
    if IMPERATIVE_VERBS[word] then
      has_verb = true
    elseif not ABSTRACT_OBJECTS[word] and word:len() > 2 and not VAGUE_VERBS[word] then
      concrete_object = true
    end
  end
  return has_verb and concrete_object
end

local MODEL_PROMPT = table.concat({
  "NVIME INTENT CLASSIFIER MODE.",
  "",
  "You are classifying whether a user's edit intent is concrete enough for a constrained patch worker to act on.",
  "Output FORMAT (mandatory):",
  "  - FIRST non-empty line MUST be exactly one of:",
  "      VERDICT: ok",
  "      VERDICT: vague",
  "      VERDICT: questionable",
  "  - Optional second line: one-sentence justification.",
  "",
  "Definitions:",
  "  ok            — names a concrete change verb (add/remove/rename/fix/replace/implement/update)",
  "                  AND a concrete object (file/function/specific behavior).",
  "  vague         — phrasing like 'clean this up', 'fix bugs', 'make better', 'polish'.",
  "  questionable  — borderline; could be acted on but lacks specificity.",
  "",
  "Bias toward 'questionable' over 'ok' when unsure. Bias toward 'vague' when the intent is short or contains only vague verbs.",
  "",
  "Intent:",
}, "\n")

-- Run the model classifier synchronously. Uses agents.run + vim.wait so the
-- caller (intent.classify → intent.guard → edit.start) keeps its sync
-- contract. Times out after intent.model_timeout_ms; on any failure falls
-- through to the heuristic. Caches the result by intent hash.
local function classify_with_model(intent_text)
  local ok_agents, agents = pcall(require, "nvime.agents")
  if not ok_agents or not agents or type(agents.run) ~= "function" then
    return nil
  end
  local provider = (state.config and state.config.provider) or "claude"
  local timeout_ms = tonumber(cfg().model_timeout_ms) or DEFAULT_MODEL_TIMEOUT_MS
  local response = {}
  local done = false
  local handle = agents.run({
    provider = provider,
    lane = "critic", -- reuses the read-only, no-edit, no-MCP lane shape
    -- A tiny structured classifier that never runs commands — skip CLAUDE.md.
    no_project_guidance = true,
    prompt = MODEL_PROMPT .. "\n" .. intent_text,
    on_text = function(text)
      response[#response + 1] = text
    end,
    on_progress = function() end,
    on_exit = function()
      done = true
    end,
  })
  local finished = vim.wait(timeout_ms, function()
    return done
  end, 50)
  if not finished then
    if handle and type(handle.kill) == "function" then
      pcall(handle.kill)
    end
    return nil
  end
  local raw = table.concat(response)
  for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
    local upper = vim.trim(line):upper()
    if upper:find("^VERDICT:%s*OK") then
      return "ok"
    end
    if upper:find("^VERDICT:%s*VAGUE") then
      return "vague"
    end
    if upper:find("^VERDICT:%s*QUESTIONABLE") then
      return "questionable"
    end
  end
  return nil
end

-- Public: classify an intent string. Side-effect free.
function M.classify(intent)
  if not enabled() then
    return { verdict = "ok", reason = "intent linter disabled" }
  end
  if type(intent) ~= "string" or vim.trim(intent) == "" then
    return { verdict = "ok", reason = "empty intent" }
  end
  local trimmed = vim.trim(intent)
  local words = lower_words(trimmed)
  if #words < min_words() then
    return {
      verdict = "vague",
      reason = string.format("intent has %d words, fewer than min_words=%d", #words, min_words()),
      suggestions = {
        "Name the concrete change (e.g. 'replace foo(x) call with bar(x)').",
        "If you wanted review or diagnosis, prefer NvimeAsk over NvimeEdit.",
      },
    }
  end
  local phrase = contains_any_phrase(trimmed, VAGUE_PHRASES)
  if phrase then
    return {
      verdict = "vague",
      reason = "intent contains vague phrase: '" .. phrase .. "'",
      suggestions = {
        "Replace the vague phrase with a specific bug, missing feature, or literal request.",
      },
    }
  end
  local has_imperative = false
  local has_vague_verb = false
  for _, word in ipairs(words) do
    if IMPERATIVE_VERBS[word] then
      has_imperative = true
    end
    if VAGUE_VERBS[word] then
      has_vague_verb = true
    end
  end
  if has_vague_verb and not has_imperative then
    return {
      verdict = "vague",
      reason = "intent has only vague verbs (no concrete change verb)",
      suggestions = {
        "Use a concrete verb: add / remove / rename / replace / fix / update / extract / inline.",
      },
    }
  end
  if not looks_concrete(words) then
    local result = {
      verdict = "questionable",
      reason = "intent does not name both a concrete verb and a concrete object",
      suggestions = {
        "Reference the file, function, or specific behavior the change should target.",
      },
    }
    -- Optional model upgrade: only consulted when the heuristic returns
    -- questionable. The model can promote to ok (intent is fine) or
    -- demote to vague (intent is hopeless). Cached on disk by intent hash.
    if cfg().classifier == "model" then
      local key = djb2(trimmed)
      local cache = read_cache()
      local cached = cache[key]
      if cached then
        result.verdict = cached
        result.reason = "model verdict (cached): " .. cached
      else
        local verdict = classify_with_model(trimmed)
        if verdict then
          cache[key] = verdict
          write_cache(cache)
          result.verdict = verdict
          result.reason = "model verdict: " .. verdict
        end
      end
    end
    return result
  end
  return { verdict = "ok", reason = "ok" }
end

-- Public: prompt-or-refuse helper. Returns true to proceed, false to
-- abort. For `vague` verdicts it asks for confirmation via vim.fn.confirm
-- so the user has to type a deliberate choice; for `questionable` it just
-- notifies and proceeds (the heuristic is too cheap to block on alone).
function M.guard(intent, opts)
  opts = opts or {}
  if not enabled() then
    return true
  end
  local result = M.classify(intent)
  if result.verdict == "ok" then
    return true
  end
  if result.verdict == "questionable" then
    vim.schedule(function()
      vim.notify("nvime intent: " .. result.reason .. " (sending anyway)", vim.log.levels.INFO)
    end)
    return true
  end
  -- vague: confirm
  local audit = require("nvime.audit")
  local lines = { "nvime intent linter: " .. result.reason }
  for _, suggestion in ipairs(result.suggestions or {}) do
    lines[#lines + 1] = "  - " .. suggestion
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Send anyway?"
  local choice
  if opts.assume_yes then
    choice = 1
  else
    choice = vim.fn.confirm(table.concat(lines, "\n"), "&Send\n&Cancel", 2)
  end
  if choice == 1 then
    audit.write({
      event = "intent_override",
      verdict = result.verdict,
      reason = result.reason,
      lane = opts.lane,
    })
    return true
  end
  audit.write({
    event = "intent_block",
    verdict = result.verdict,
    reason = result.reason,
    lane = opts.lane,
  })
  return false
end

return M
