local agents = require("nvime.agents")
local audit = require("nvime.audit")
local git = require("nvime.git")
local state = require("nvime.state")

-- :NvimeRecap — reverse-direction "explain my changes" lane.
--
-- Given a git diff (working tree, --cached, or A..B), spawns the plan-lane
-- agent in a hardened temp workspace and asks it to produce a plan.md
-- narrative + stub plan.json under .nvime/plans/recap-<hash>/. The existing
-- plan-lane sync filter already restricts writes to .nvime/plans/, so the
-- agent cannot modify anything else even though it has Write permissions.
--
-- This is the antidote to "work happened outside nvime and now nobody
-- understands it" — turn an existing diff into an after-the-fact plan you
-- can read like the architect always did.

local M = {}

local function uv()
  return vim.uv or vim.loop
end

local function repo_root()
  return git.root(uv().cwd()) or uv().cwd()
end

local function compute_diff(opts)
  local root = repo_root()
  local cmd = {
    "git",
    "-C",
    root,
    "diff",
    "--no-ext-diff",
    "--no-color",
    "--find-renames",
    "--find-copies",
    "--unified=10",
  }
  if opts.cached then
    cmd[#cmd + 1] = "--cached"
  end
  if opts.range and opts.range ~= "" then
    cmd[#cmd + 1] = opts.range
  end
  if opts.paths then
    cmd[#cmd + 1] = "--"
    for _, p in ipairs(opts.paths) do
      cmd[#cmd + 1] = p
    end
  end
  return table.concat(git.systemlist(cmd), "\n"), cmd
end

local function compute_label(opts)
  if opts.range and opts.range ~= "" then
    return opts.range
  end
  if opts.cached then
    return "staged changes"
  end
  return "working tree"
end

-- Stable short hash of the diff body so recurring recaps of the same diff
-- overwrite the same recap directory rather than piling up.
local function short_hash(body)
  local h = 5381
  for i = 1, #body do
    h = ((h * 33) + body:byte(i)) % 0xFFFFFFFF
  end
  return string.format("%08x", h):sub(1, 8)
end

local function build_recap_prompt(diff_body, label, recap_id)
  local lines = {
    "NVIME RECAP MODE.",
    "",
    "You are summarizing an EXISTING code change, not authoring a new plan.",
    "You MUST NOT modify any source code.",
    "You MAY ONLY write to `.nvime/plans/" .. recap_id .. "/plan.md` and",
    "`.nvime/plans/" .. recap_id .. "/plan.json`. nvime's sync filter drops",
    "anything else you write outside `.nvime/plans/`.",
    "",
    "Tools available:",
    "  - Read, Grep, LS, Glob — to study the surrounding code.",
    "  - Bash — to inspect git history (git log, git blame), to confirm",
    "    line numbers, to run cheap checks.",
    "  - Web — only if explicitly relevant.",
    "  - Write/Edit/MultiEdit — ONLY under `.nvime/plans/" .. recap_id .. "/`.",
    "",
    "Workflow:",
    "  1. Read the unified diff at the bottom of this prompt CAREFULLY.",
    "  2. For each logically distinct hunk, work out:",
    "     - WHAT changed (concretely; cite the file and line range)",
    "     - WHY it likely changed (read surrounding code if needed)",
    "     - What invariants the change preserves or breaks",
    "     - What is NOT covered by tests in the current diff",
    "  3. Group multiple hunks that serve one intent under a single",
    "     'change unit' in the narrative.",
    "  4. Write `.nvime/plans/" .. recap_id .. "/plan.md` — a Markdown",
    "     narrative a future engineer can read cold. Required sections:",
    "       # Recap · " .. label,
    "       ## Summary (one paragraph)",
    "       ## Files touched (list with one-line rationale each)",
    "       ## Change units (numbered: WHAT, WHY, RISKS)",
    "       ## Untested behavior (concrete test cases worth adding)",
    "       ## Suggested follow-up plan (1-3 next steps if relevant)",
    "  5. Write `.nvime/plans/" .. recap_id .. "/plan.json`. Schema:",
    "     {",
    '       "version": 1,',
    '       "id": "' .. recap_id .. '",',
    '       "title": "Recap · ' .. label .. '",',
    '       "why": "<one paragraph mirroring plan.md Summary>",',
    '       "created_at": <unix ts>,',
    '       "files_estimated": [<files touched in this diff>],',
    '       "acceptance": [],',
    '       "steps": [],',
    '       "recap": true',
    "     }",
    "  6. Emit ONE final marker as your last line of output (no other prose",
    "     after it):",
    "",
    "NVIME_PLAN",
    "```json",
    '{ "id": "' .. recap_id .. '", "summary": "...", "step_count": 0, "files_estimated": [...] }',
    "```",
    "",
    "Quality bar:",
    "  - Cite real files and line ranges.",
    "  - Do not invent intent: when 'why' is uncertain, say so explicitly.",
    "  - Be honest about what is untested. The user reads this BEFORE",
    "    committing — anything you mark covered they will trust.",
    "",
    "Diff label: " .. label,
    "",
    "Unified diff:",
    "```diff",
    diff_body,
    "```",
  }
  return table.concat(lines, "\n")
end

local function ensure_recap_id(diff_body)
  return "recap-" .. short_hash(diff_body)
end

function M.start(opts)
  opts = opts or {}
  if state.disabled then
    vim.notify("nvime is disabled; run :NvimeEnable first", vim.log.levels.WARN)
    return
  end
  -- Indirect through the module-level alias so tests can stub the diff
  -- computation without spawning a real agent.
  local diff_body, cmd = M._compute_diff(opts)
  if not diff_body or vim.trim(diff_body) == "" then
    vim.notify("nvime recap: git diff is empty (range=" .. (opts.range or "(working tree)") .. ")", vim.log.levels.INFO)
    return
  end
  local recap_id = ensure_recap_id(diff_body)
  local label = compute_label(opts)
  local provider = opts.provider or (state.config and state.config.provider) or "claude"
  local prompt = build_recap_prompt(diff_body, label, recap_id)

  audit.write({
    event = "recap_start",
    provider = provider,
    recap_id = recap_id,
    label = label,
    cmd = table.concat(cmd, " "),
    diff_bytes = #diff_body,
  })

  -- Reuse the plan lane: same workspace isolation, same .nvime/plans/-only
  -- sync filter. The agent writes plan.md + plan.json under the recap-id
  -- directory and only those paths come back to the user's repo.
  local handle
  local response = {}
  vim.notify("nvime recap: drafting " .. recap_id .. " (provider " .. provider .. ")", vim.log.levels.INFO)
  agents.run({
    provider = provider,
    lane = "plan",
    prompt = prompt,
    persist_session = false,
    on_text = function(text)
      response[#response + 1] = text
    end,
    on_progress = function() end,
    on_handle = function(h)
      handle = h
    end,
    on_exit = function(result)
      local synced = result.nvime_synced_plan_files or {}
      audit.write({
        event = "recap_exit",
        recap_id = recap_id,
        provider = provider,
        code = result.code,
        synced_plan_files = synced,
      })
      if result.code ~= 0 then
        vim.notify("nvime recap: agent exited with code " .. tostring(result.code), vim.log.levels.ERROR)
        return
      end
      if #synced == 0 then
        vim.notify(
          "nvime recap: agent did not write any plan files; the recap may have been refused.",
          vim.log.levels.WARN
        )
        return
      end
      vim.schedule(function()
        local ok_plan, plan = pcall(require, "nvime.plan")
        if ok_plan and plan then
          plan.refresh()
          if plan.get(recap_id) then
            vim.notify(
              "nvime recap: " .. recap_id .. " ready (" .. #synced .. " file(s)). Press <leader>nP to view.",
              vim.log.levels.INFO
            )
            -- Auto-open the recap when the user has not opted out.
            local cfg = (state.config or {}).recap or {}
            if cfg.auto_open ~= false then
              plan.open(recap_id)
            end
          else
            vim.notify(
              "nvime recap: synced files but no plan.json — open .nvime/plans/" .. recap_id,
              vim.log.levels.WARN
            )
          end
        end
      end)
    end,
  })
  return handle
end

-- Parse the `:NvimeRecap` argv into structured opts. Supported forms:
--   :NvimeRecap                    → working-tree diff
--   :NvimeRecap --cached           → staged diff
--   :NvimeRecap A..B               → range diff
--   :NvimeRecap [claude|codex] ... → optional leading provider
function M.command(args)
  args = args or {}
  local fargs = args.fargs or {}
  local provider = nil
  if fargs[1] == "claude" or fargs[1] == "codex" then
    provider = table.remove(fargs, 1)
  end
  local opts = { provider = provider }
  for _, arg in ipairs(fargs) do
    if arg == "--cached" or arg == "--staged" then
      opts.cached = true
    elseif arg:find("%.%.") then
      opts.range = arg
    else
      vim.notify("nvime recap: unknown arg `" .. arg .. "`", vim.log.levels.WARN)
      return
    end
  end
  return M.start(opts)
end

M._compute_diff = compute_diff
M._build_recap_prompt = build_recap_prompt
M._ensure_recap_id = ensure_recap_id

return M
