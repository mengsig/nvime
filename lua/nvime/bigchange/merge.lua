-- nvime.bigchange.merge
--
-- Stage 6: land the work. The agent never commits in the worktree; instead we
-- diff the worktree against its base commit and apply that patch as UNSTAGED
-- changes onto a fresh branch in the MAIN working tree. From there gitflow (or
-- plain git) takes over — the user controls every commit.

local git = require("nvime.git")
local store = require("nvime.bigchange.store")

local M = {}

local function slugify(text)
  local slug = (text or "change"):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if slug == "" then
    slug = "change"
  end
  return slug:sub(1, 40)
end

local function git_ok(out)
  return vim.v.shell_error == 0, table.concat(out or {}, "\n")
end

-- cb is called after a successful merge so callers (review) can re-render.
function M.start(session, cb)
  cb = cb or function() end
  local root = git.root()
  if not root then
    vim.notify("nvime bigchange: not in a git repository", vim.log.levels.ERROR)
    return
  end
  if not session.worktree or vim.fn.isdirectory(session.worktree) ~= 1 then
    vim.notify("nvime bigchange: worktree missing", vim.log.levels.ERROR)
    return
  end

  -- Warn on a dirty main tree — applying a patch could collide.
  local dirty = git.systemlist({ "git", "-C", root, "status", "--porcelain" })
  if #dirty > 0 then
    local choice = vim.fn.confirm(
      "Main working tree has uncommitted changes; applying the Big Change may conflict.\nProceed anyway?",
      "&Proceed\n&Cancel",
      2
    )
    if choice ~= 1 then
      return
    end
  end

  vim.ui.input({ prompt = "Branch name: ", default = "bigchange/" .. slugify(session.title) }, function(branch)
    if not branch or vim.trim(branch) == "" then
      vim.notify("nvime bigchange: merge cancelled", vim.log.levels.INFO)
      return
    end
    branch = vim.trim(branch)

    -- 1. Generate the patch from the worktree (incl. untracked via intent-to-add).
    local patch
    store.with_trusted(function()
      git.systemlist({ "git", "-C", session.worktree, "add", "-A", "-N" })
      patch = git.systemlist({ "git", "-C", session.worktree, "diff", "--binary", session.base_commit or "HEAD" })
    end)
    if not patch or #patch == 0 then
      vim.notify("nvime bigchange: no changes to merge", vim.log.levels.WARN)
      return
    end
    local patch_file = vim.fn.tempname() .. ".patch"
    vim.fn.writefile(patch, patch_file)

    -- 2. Create the branch from the SAME base the worktree (and patch) were
    -- built on, so the patch context always matches — even if the main branch
    -- advanced since the build started.
    local start_point = session.base_commit or "HEAD"
    local prior_branch = session.base_branch
    local created_ok, created_out
    store.with_trusted(function()
      local out = git.systemlist({ "git", "-C", root, "checkout", "-b", branch, start_point })
      created_ok, created_out = git_ok(out)
    end)
    if not created_ok then
      vim.notify("nvime bigchange: could not create branch '" .. branch .. "':\n" .. created_out, vim.log.levels.ERROR)
      return
    end

    -- 3. Apply the patch as unstaged working-tree changes.
    local applied_ok, applied_out
    store.with_trusted(function()
      local out = git.systemlist({ "git", "-C", root, "apply", "--whitespace=nowarn", patch_file })
      applied_ok, applied_out = git_ok(out)
      if not applied_ok then
        -- Retry with 3-way in case the base drifted.
        out = git.systemlist({ "git", "-C", root, "apply", "--3way", "--whitespace=nowarn", patch_file })
        applied_ok, applied_out = git_ok(out)
      end
    end)
    if not applied_ok then
      -- Roll back so the user is left where they started, not stranded on an
      -- empty branch. Restore their original branch and delete the new one.
      store.with_trusted(function()
        if prior_branch and prior_branch ~= "" and prior_branch ~= "HEAD" then
          git.systemlist({ "git", "-C", root, "checkout", prior_branch })
        else
          git.systemlist({ "git", "-C", root, "checkout", start_point })
        end
        git.systemlist({ "git", "-C", root, "branch", "-D", branch })
      end)
      vim.notify(
        "nvime bigchange: patch did not apply cleanly; rolled back to '"
          .. (prior_branch or start_point)
          .. "'. Patch saved at: "
          .. patch_file,
        vim.log.levels.ERROR
      )
      return
    end

    session.status = store.STATUS.MERGED
    session.merged_branch = branch
    store.touch(session)
    pcall(vim.fn.delete, patch_file)
    vim.notify(
      "nvime bigchange: merged onto '"
        .. branch
        .. "' (unstaged). Use gitflow / git to stage & commit. The worktree is kept; discard it from the picker.",
      vim.log.levels.INFO
    )
    cb()
  end)
end

return M
