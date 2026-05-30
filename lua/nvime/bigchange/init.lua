-- nvime.bigchange
--
-- Public entry point for the "Big Change" lane (<leader>nB): an AI-driven
-- feature-implementation engine gated behind a forced-comprehension PR review.
--
-- Flow (see store.lua for the status enum):
--   intake   → agent asks clarifying questions, writes a spec, you approve
--   building → agent implements full-auto in a dedicated git worktree
--   review   → agent-chosen semantic blocks gated by approve / request-changes
--   merged   → work lands unstaged on a branch you name; gitflow takes over
--
-- This file owns session creation + routing; the per-status surfaces live in
-- sibling modules (intake.lua, build.lua, review/*.lua) wired in later stages.

local store = require("nvime.bigchange.store")

local M = {}

-- Open the Big Changes picker (the "PRs" list). The escape hatch reached via
-- :NvimeBigChange even when a draft is in progress.
function M.open_picker()
  require("nvime.bigchange.picker").open()
end

-- The most-recently-touched in-progress draft, if any.
local function active_draft()
  for _, session in ipairs(store.list()) do
    if session.status == store.STATUS.DRAFT then
      return session
    end
  end
  return nil
end

-- <leader>nB entry point: resume an in-progress draft if there is one,
-- otherwise show the picker.
function M.open()
  local draft = active_draft()
  if draft then
    require("nvime.bigchange.draft").open(draft)
    return
  end
  M.open_picker()
end

-- Resolve the provider to use for a new Big Change. Prefers the user's active
-- provider, falling back to the configured default.
local function default_provider()
  local ok, provider = pcall(require, "nvime.provider")
  if ok and type(provider.current) == "function" then
    local name = provider.current()
    if name and name ~= "" then
      return name
    end
  end
  local cfg = require("nvime.state").config or {}
  return cfg.provider or "claude"
end

-- Surfaces are landed stage by stage; route defensively so a not-yet-built
-- status degrades to a friendly notice instead of a stacktrace.
local STATUS_SURFACE = {
  [store.STATUS.DRAFT] = "nvime.bigchange.draft",
  [store.STATUS.INTAKE] = "nvime.bigchange.intake",
  [store.STATUS.BUILDING] = "nvime.bigchange.build",
  [store.STATUS.REVIEW] = "nvime.bigchange.review",
  [store.STATUS.MERGED] = "nvime.bigchange.review",
}

-- Route to the right surface for a session based on its status.
function M.open_session(id)
  local session = store.get(id)
  if not session then
    vim.notify("nvime bigchange: session not found", vim.log.levels.WARN)
    return
  end
  store.set_active(session.id)
  local module_name = STATUS_SURFACE[session.status]
  local ok, surface = pcall(require, module_name)
  if not ok or type(surface.open) ~= "function" then
    vim.notify(
      string.format("nvime bigchange: '%s' surface not available yet (%s)", session.status, session.title),
      vim.log.levels.INFO
    )
    return
  end
  surface.open(session)
end

-- Interactive new-session flow: pick difficulty, then open a structured draft
-- brief to author. The brief (Title/Context/Goal/Notes/Acceptance) is persisted
-- and feeds intake on submit. `on_done` (optional) refreshes the caller (e.g.
-- the picker) after creation.
function M.create_interactive(on_done)
  local items = {}
  for _, key in ipairs(store.DIFFICULTY_ORDER) do
    local d = store.DIFFICULTY[key]
    items[#items + 1] = { key = key, label = string.format("%-8s — %s", d.label, d.detail) }
  end
  vim.ui.select(items, {
    prompt = "Difficulty (how strict is the review?):",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    local session = store.create({
      title = "Untitled draft",
      difficulty = choice.key,
      provider = default_provider(),
    })
    session.status = store.STATUS.DRAFT
    store.touch(session)
    if type(on_done) == "function" then
      pcall(on_done)
    end
    require("nvime.bigchange.draft").open(session)
  end)
end

-- Remove a session's worktree (if any) and delete the record.
function M.discard(id)
  local session = store.get(id)
  if not session then
    return
  end
  if session.worktree and session.worktree ~= "" and vim.fn.isdirectory(session.worktree) == 1 then
    local git = require("nvime.git")
    local root = git.repo_root()
    -- Remove the linked worktree, then prune the administrative entry.
    git.systemlist({ "git", "-C", root, "worktree", "remove", "--force", session.worktree })
    git.systemlist({ "git", "-C", root, "worktree", "prune" })
  end
  store.delete(id)
  vim.notify("nvime bigchange: discarded '" .. (session.title or session.id) .. "'", vim.log.levels.INFO)
end

function M.flush()
  store.flush()
end

return M
