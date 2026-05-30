-- nvime.bigchange.build
--
-- Stage 3: the "go crazy" phase. Creates a detached git worktree OUTSIDE the
-- repo (so the main working tree is never touched), then runs the agent
-- full-auto inside it (lane="bigchange") to implement the approved spec. The
-- run is async — a streaming progress float reports what the agent is doing
-- while you keep working. On completion we extract the diff into semantic
-- blocks (Stage 4) and open the review.

local agent = require("nvime.bigchange.agent")
local git = require("nvime.git")
local store = require("nvime.bigchange.store")
local ui = require("nvime.ui")

local M = {}

local view = {
  session = nil,
  bufnr = nil,
  winid = nil,
  ns = vim.api.nvim_create_namespace("nvime.bigchange.build"),
  lines = {},
  render_scheduled = false,
}

local function is_open()
  return view.winid and vim.api.nvim_win_is_valid(view.winid) and view.bufnr and vim.api.nvim_buf_is_valid(view.bufnr)
end

-- ---------------------------------------------------------------------------
-- progress float
-- ---------------------------------------------------------------------------
local function render()
  view.render_scheduled = false
  if not is_open() then
    return
  end
  vim.bo[view.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, view.lines)
  vim.bo[view.bufnr].modifiable = false
  pcall(vim.api.nvim_win_set_cursor, view.winid, { #view.lines, 0 })
end

local function schedule_render()
  if view.render_scheduled then
    return
  end
  view.render_scheduled = true
  vim.schedule(render)
end

local function append(text)
  if not text or text == "" then
    return
  end
  for _, line in ipairs(vim.split(text:gsub("\r", ""), "\n", { plain = true })) do
    view.lines[#view.lines + 1] = "  " .. line
  end
  schedule_render()
end

local function open_panel(session)
  if is_open() then
    vim.api.nvim_set_current_win(view.winid)
    return
  end
  view.bufnr, view.winid = require("nvime.bigchange.uikit").open_float({
    title = ui.icon("brand") .. "  Building: " .. (session.title or ""),
    footer = "agent is working — you can q to background it",
    width_ratio = 0.8,
    height_ratio = 0.8,
    min_width = 60,
    min_height = 16,
    wrap = true,
  })
  vim.keymap.set("n", "q", function()
    if view.winid and vim.api.nvim_win_is_valid(view.winid) then
      pcall(vim.api.nvim_win_close, view.winid, true)
    end
    view.winid = nil
  end, { buffer = view.bufnr, silent = true, nowait = true })
end

-- ---------------------------------------------------------------------------
-- worktree
-- ---------------------------------------------------------------------------
-- Ensure the session has a detached worktree. Returns root, or nil + error.
local function ensure_worktree(session)
  local root = git.root()
  if not root then
    return nil, "not inside a git repository"
  end

  local path = store.worktree_path(session)
  -- Reuse an existing worktree as-is: its base_commit was recorded on the
  -- first build, and re-resolving from the (possibly advanced) main HEAD here
  -- would make the later `git diff <base_commit>` compare against the wrong
  -- base and surface unrelated commits as spurious hunks.
  if vim.fn.isdirectory(path) == 1 and session.base_commit then
    session.worktree = path
    return root
  end

  -- Fresh worktree: record the base we branch from (used by the merge handoff).
  local head = git.systemlist({ "git", "-C", root, "rev-parse", "HEAD" })
  session.base_commit = head[1] and vim.trim(head[1]) or nil
  local branch = git.systemlist({ "git", "-C", root, "rev-parse", "--abbrev-ref", "HEAD" })
  session.base_branch = branch[1] and vim.trim(branch[1]) or nil
  if not session.base_commit then
    return nil, "could not resolve HEAD"
  end

  vim.fn.mkdir(store.worktree_root(), "p")
  local out
  store.with_trusted(function()
    out = git.systemlist({ "git", "-C", root, "worktree", "add", "--detach", path, session.base_commit })
  end)
  if vim.fn.isdirectory(path) ~= 1 then
    return nil, "git worktree add failed: " .. table.concat(out or {}, " ")
  end
  session.worktree = path
  return root
end

-- ---------------------------------------------------------------------------
-- build
-- ---------------------------------------------------------------------------
local function build_done(session, text, result)
  session.busy = false
  append("")
  append(
    "──────────────────────────────────────────────"
  )
  if result and result.code and result.code ~= 0 then
    append("⚠ agent exited with code " .. tostring(result.code))
  end
  if text and text ~= "" then
    append(text)
  end
  store.touch(session)

  append("")
  append("Extracting changes into review blocks…")
  require("nvime.bigchange.blocks").extract(session, function(ok, err)
    if not ok then
      append("⚠ " .. tostring(err or "no changes detected"))
      -- No diff → nothing to review. Stay in building so the user can retry.
      session.status = store.STATUS.BUILDING
      store.touch(session)
      return
    end
    session.status = store.STATUS.REVIEW
    store.touch(session)
    if is_open() then
      pcall(vim.api.nvim_win_close, view.winid, true)
      view.winid = nil
    end
    require("nvime.bigchange.review").open(session)
  end)
end

function M.start(session)
  view.session = session
  view.lines = {}
  open_panel(session)
  append(ui.icon("brand") .. "  Big Change: " .. (session.title or ""))
  append("Creating isolated worktree…")

  local root, err = ensure_worktree(session)
  if not root then
    append("⚠ " .. tostring(err))
    return
  end
  append("worktree: " .. session.worktree)
  append("base: " .. (session.base_branch or "?") .. " @ " .. (session.base_commit or ""):sub(1, 10))
  append("")
  append("Agent is implementing the spec full-auto. This may take a while…")
  append(
    "──────────────────────────────────────────────"
  )

  session.status = store.STATUS.BUILDING
  session.busy = true
  store.touch(session)

  agent.turn({
    session = session,
    lane = "bigchange",
    cwd = session.worktree,
    prompt = agent.build_prompt(session),
    -- First build starts fresh IN the worktree; the spec carries all intake
    -- context, so we never resume the repo-root intake session here (it isn't
    -- resolvable from the worktree's project dir). Later worktree turns
    -- (blocks/grading) resume the session this build creates.
    resume = true,
    scope = "worktree",
    on_progress = function(line)
      append(line)
    end,
    on_done = function(text, result)
      build_done(session, text, result)
    end,
  })
end

-- Re-open the build progress for a session that's still building, or kick a
-- (re)build for one that hasn't produced reviewable changes yet.
function M.open(session)
  if session.busy then
    open_panel(session)
    render()
    return
  end
  M.start(session)
end

return M
