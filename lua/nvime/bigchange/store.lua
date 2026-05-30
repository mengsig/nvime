-- nvime.bigchange.store
--
-- Persistence + data model for "Big Change" sessions — the AI-driven feature
-- implementation + forced-comprehension PR review lane (<leader>nB).
--
-- A Big Change session moves through four statuses:
--   intake   — agent asks clarifying questions, writes a spec, user approves
--   building — agent implements full-auto inside a dedicated git worktree
--   review   — agent-chosen semantic blocks gated by approve/request-changes
--   merged   — work landed as an unstaged branch in the main tree (gitflow takes over)
--
-- The on-disk envelope mirrors panel.lua's session format (version /
-- next_session_id / sessions) so it reads the same to anyone who knows that
-- file. State lives at .nvime/bigchange-sessions.json in the git root; the
-- build worktrees live OUTSIDE the repo under stdpath('data') so they never
-- pollute the repo's git status.

local git = require("nvime.git")

local M = {}

local STORE_VERSION = 1
local PERSIST_FILENAME = "bigchange-sessions.json"

M.STATUS = {
  DRAFT = "draft",
  INTAKE = "intake",
  BUILDING = "building",
  REVIEW = "review",
  MERGED = "merged",
}

-- Difficulty → minimum explanation grade (%) required to clear a block.
-- "vibe" is the sentinel for "Approve clears instantly, no explanation".
M.DIFFICULTY = {
  vibe = { label = "vibe", threshold = nil, detail = "no explanation required" },
  easy = { label = "easy", threshold = 40, detail = "general architecture" },
  medium = { label = "medium", threshold = 70, detail = "per-block intent + why" },
  extreme = { label = "extreme", threshold = 90, detail = "near line-by-line" },
}

M.DIFFICULTY_ORDER = { "vibe", "easy", "medium", "extreme" }

-- Run fn inside nvime's trusted scope so the policy guard permits the git
-- subprocesses the Big Change lane spawns. Shared by build/blocks/review/merge
-- (lives here, the lightest module they all already require).
function M.with_trusted(fn)
  local ok, policy = pcall(require, "nvime.policy")
  if ok and type(policy.with_trusted) == "function" then
    return policy.with_trusted(fn)
  end
  return fn()
end

-- In-memory store. Loaded lazily from disk on first access.
local data = {
  loaded = false,
  next_session_id = 1,
  sessions = {},
  active_session_id = nil,
}

local save_pending = false

-- ---------------------------------------------------------------------------
-- paths
-- ---------------------------------------------------------------------------
local function sessions_path()
  local root = git.root()
  if root then
    return root .. "/.nvime/" .. PERSIST_FILENAME
  end
  return vim.fn.stdpath("state") .. "/nvime/" .. PERSIST_FILENAME
end

-- A stable, filesystem-safe identifier for the current repo, used to bucket
-- worktrees under the global data dir. Derived from the git root path so two
-- different checkouts of the same repo don't collide.
function M.repo_slug()
  local root = git.repo_root()
  local base = vim.fn.fnamemodify(root, ":t")
  if base == nil or base == "" then
    base = "repo"
  end
  local hash = vim.fn.sha256 and vim.fn.sha256(root):sub(1, 8) or tostring(#root)
  return (base:gsub("[^%w%-_]", "_")) .. "-" .. hash
end

-- Root directory for this repo's build worktrees, outside the repo tree.
function M.worktree_root()
  return string.format("%s/nvime/bigchange/%s", vim.fn.stdpath("data"), M.repo_slug())
end

function M.worktree_path(session)
  return M.worktree_root() .. "/" .. tostring(session.id)
end

-- ---------------------------------------------------------------------------
-- persistence
-- ---------------------------------------------------------------------------
local function now()
  return os.time()
end

local function serialize(session)
  return {
    id = session.id,
    title = session.title,
    status = session.status,
    difficulty = session.difficulty,
    provider = session.provider,
    goal = session.goal,
    -- The user-authored brief (markdown) before intake; reopenable as a draft.
    draft = session.draft,
    spec = session.spec,
    spec_approved = session.spec_approved == true,
    -- The live structured plan (clarifying decisions + the user's in-progress
    -- selections) so an interrupted intake reopens exactly where it left off.
    plan = session.plan,
    -- A half-typed "message the agent" draft, cached until sent.
    message_draft = session.message_draft,
    provider_sessions = session.provider_sessions or {},
    worktree_sessions = session.worktree_sessions or {},
    worktree = session.worktree,
    base_commit = session.base_commit,
    base_branch = session.base_branch,
    blocks = session.blocks or {},
    -- Persist the parsed diff hunks: blocks only carry hunk_ids, so without
    -- this the review pane (block_hunks) renders empty after any reload.
    diff_hunks = session.diff_hunks or {},
    intake_history = session.intake_history or {},
    review_round = session.review_round or 0,
    merged_branch = session.merged_branch,
    created_at = session.created_at,
    updated_at = session.updated_at,
  }
end

local function normalize(item)
  item.id = tonumber(item.id)
  item.status = item.status or M.STATUS.INTAKE
  item.difficulty = item.difficulty or "medium"
  item.provider_sessions = item.provider_sessions or {}
  item.worktree_sessions = item.worktree_sessions or {}
  item.blocks = item.blocks or {}
  item.diff_hunks = item.diff_hunks or {}
  item.intake_history = item.intake_history or {}
  item.spec_approved = item.spec_approved == true
  item.review_round = tonumber(item.review_round) or 0
  -- Runtime-only fields never trusted from disk.
  item.busy = false
  item.process = nil
  item.bufnr = nil
  return item
end

function M.save_now()
  if not data.loaded then
    return
  end
  local out = {}
  -- Newest first, mirroring panel.lua's sort-by-updated_at.
  local order = {}
  for index in ipairs(data.sessions) do
    order[#order + 1] = index
  end
  table.sort(order, function(a, b)
    return ((data.sessions[a] or {}).updated_at or 0) > ((data.sessions[b] or {}).updated_at or 0)
  end)
  for _, index in ipairs(order) do
    out[#out + 1] = serialize(data.sessions[index])
  end

  local path = sessions_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "w")
  if not fd then
    vim.schedule(function()
      vim.notify("nvime bigchange: could not persist sessions: " .. tostring(err), vim.log.levels.WARN)
    end)
    return
  end
  local ok, write_err = pcall(function()
    fd:write(vim.json.encode({
      version = STORE_VERSION,
      next_session_id = data.next_session_id,
      active_session_id = data.active_session_id,
      sessions = out,
    }))
    fd:write("\n")
  end)
  fd:close()
  if not ok then
    vim.schedule(function()
      vim.notify("nvime bigchange: persist failed: " .. tostring(write_err), vim.log.levels.WARN)
    end)
  end
end

function M.schedule_save()
  if save_pending then
    return
  end
  save_pending = true
  vim.defer_fn(function()
    save_pending = false
    M.save_now()
  end, 150)
end

function M.load()
  if data.loaded then
    return
  end
  data.loaded = true
  local path = sessions_path()
  if vim.fn.filereadable(path) ~= 1 then
    return
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or not raw or #raw == 0 then
    return
  end
  local decoded_ok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
  if not decoded_ok or type(decoded) ~= "table" or type(decoded.sessions) ~= "table" then
    return
  end
  if (tonumber(decoded.version) or 1) > STORE_VERSION then
    vim.notify("nvime bigchange: session file is from a newer version: " .. path, vim.log.levels.WARN)
    return
  end
  data.sessions = {}
  local max_id = 0
  for _, item in ipairs(decoded.sessions) do
    if type(item) == "table" and item.id then
      normalize(item)
      if item.id then
        max_id = math.max(max_id, item.id)
        data.sessions[#data.sessions + 1] = item
      end
    end
  end
  data.next_session_id = math.max(tonumber(decoded.next_session_id) or 1, max_id + 1)
  data.active_session_id = tonumber(decoded.active_session_id)
end

-- ---------------------------------------------------------------------------
-- accessors / mutators
-- ---------------------------------------------------------------------------
function M.list()
  M.load()
  local out = {}
  for _, session in ipairs(data.sessions) do
    out[#out + 1] = session
  end
  table.sort(out, function(a, b)
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)
  return out
end

function M.get(id)
  M.load()
  id = tonumber(id)
  for _, session in ipairs(data.sessions) do
    if session.id == id then
      return session
    end
  end
  return nil
end

function M.active()
  return M.get(data.active_session_id)
end

function M.set_active(id)
  data.active_session_id = tonumber(id)
  M.schedule_save()
end

-- opts: { title, goal, difficulty, provider }
function M.create(opts)
  M.load()
  opts = opts or {}
  local id = data.next_session_id
  data.next_session_id = id + 1
  local session = {
    id = id,
    title = opts.title or ("Big Change #" .. id),
    status = M.STATUS.INTAKE,
    difficulty = opts.difficulty or "medium",
    provider = opts.provider,
    goal = opts.goal,
    spec = nil,
    spec_approved = false,
    provider_sessions = {},
    worktree = nil,
    base_commit = nil,
    base_branch = nil,
    blocks = {},
    intake_history = {},
    review_round = 0,
    merged_branch = nil,
    created_at = now(),
    updated_at = now(),
  }
  data.sessions[#data.sessions + 1] = session
  data.active_session_id = id
  M.schedule_save()
  return session
end

function M.touch(session)
  if not session then
    return
  end
  session.updated_at = now()
  M.schedule_save()
end

function M.delete(id)
  M.load()
  id = tonumber(id)
  for index, session in ipairs(data.sessions) do
    if session.id == id then
      table.remove(data.sessions, index)
      if data.active_session_id == id then
        data.active_session_id = nil
      end
      M.schedule_save()
      return session
    end
  end
  return nil
end

function M.flush()
  M.save_now()
end

return M
