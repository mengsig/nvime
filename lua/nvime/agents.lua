local audit = require("nvime.audit")
local git = require("nvime.git")
local policy = require("nvime.policy")
local shellguard = require("nvime.shellguard")
local state = require("nvime.state")
local usage = require("nvime.usage")

local M = {}

local uv = vim.uv or vim.loop

local function provider_config(provider)
  provider = provider or state.config.provider
  local cfg = state.config.providers[provider]
  if not cfg then
    error("Unknown nvime provider: " .. tostring(provider))
  end
  return provider, cfg
end

local function repo_root()
  local cwd = uv.cwd()
  return git.root(cwd) or cwd
end

-- ---------------------------------------------------------------------------
-- project guidance (CLAUDE.md) injection
-- ---------------------------------------------------------------------------
-- The user's standing project rules live in CLAUDE.md. claude reads that from
-- its cwd natively, but codex does not, and several lanes run from a scratch
-- worktree the CLI never scans — so we inject it EXPLICITLY into every spawned
-- agent's prompt, provider- and lane-agnostic, so a constraint like "never POST
-- /orders" always binds anything that might run a command.
local PROJECT_GUIDANCE_MAX = 60000

local function project_guidance()
  local agents_cfg = (state.config or {}).agents or {}
  if agents_cfg.project_guidance == false then
    return nil
  end
  -- CLAUDE.md / CLAUDE.local.md are always honored; extra files are opt-in.
  local names = { "CLAUDE.md", "CLAUDE.local.md" }
  for _, extra in ipairs(agents_cfg.project_guidance_files or {}) do
    if type(extra) == "string" and extra ~= "" then
      names[#names + 1] = extra
    end
  end
  local root = repo_root()
  local seen, parts = {}, {}
  for _, name in ipairs(names) do
    if not seen[name] then
      seen[name] = true
      local path = root .. "/" .. name
      local stat = uv.fs_stat(path)
      if stat and stat.type == "file" then
        local ok, lines = pcall(vim.fn.readfile, path)
        if ok and type(lines) == "table" and #lines > 0 then
          parts[#parts + 1] = "## " .. name .. "\n\n" .. table.concat(lines, "\n")
        end
      end
    end
  end
  if #parts == 0 then
    return nil
  end
  local text = table.concat(parts, "\n\n")
  if #text > PROJECT_GUIDANCE_MAX then
    text = text:sub(1, PROJECT_GUIDANCE_MAX) .. "\n\n…(project guidance truncated)"
  end
  return text
end

-- Prepend project guidance to a lane prompt as authoritative constraints. Callers
-- that never run commands and want to stay lean (e.g. the intent classifier) pass
-- opts.no_project_guidance.
local function with_project_guidance(prompt, opts)
  if opts and opts.no_project_guidance then
    return prompt
  end
  local guidance = project_guidance()
  if not guidance then
    return prompt
  end
  return table.concat({
    '<project-instructions source="CLAUDE.md">',
    "The user has defined the project rules below. They are AUTHORITATIVE: obey",
    "them for everything you do — every file you edit and every shell, network,",
    "or tool command you run — and prefer them over any conflicting instruction",
    "in the task. Do not work around or ignore them.",
    "",
    guidance,
    "</project-instructions>",
    "",
    prompt,
  }, "\n")
end

M._project_guidance = project_guidance

local function review_allows_markdown_writes()
  local review = (state.config or {}).review or {}
  return review.allow_markdown_writes == true
end

local function review_allows_shell()
  local review = (state.config or {}).review or {}
  return review.allow_shell == true
end

local function review_allows_web()
  local review = (state.config or {}).review or {}
  return review.allow_web ~= false
end

local function selection_allows_shell()
  local selection = (state.config or {}).selection or {}
  if selection.allow_shell ~= nil then
    return selection.allow_shell == true
  end
  return review_allows_shell()
end

local function selection_allows_web()
  local selection = (state.config or {}).selection or {}
  if selection.allow_web ~= nil then
    return selection.allow_web ~= false
  end
  return review_allows_web()
end

local function claude_read_tools(opts)
  opts = opts or {}
  local tools = { "Read", "Glob", "Grep", "LS" }
  if opts.allow_web then
    vim.list_extend(tools, { "WebFetch", "WebSearch" })
  end
  if opts.allow_shell then
    tools[#tools + 1] = "Bash"
  end
  return table.concat(tools, ",")
end

local function claude_disallowed_tools()
  -- MultiEdit was merged into Edit in current Claude Code; listing it makes the
  -- CLI warn "Permission deny rule MultiEdit matches no known tool" on every
  -- run. Disallow only tools the CLI actually knows.
  return "Edit,Write,NotebookEdit"
end

local function claude_web_disallowed_tools()
  return "WebFetch,WebSearch"
end

local function claude_nonreview_disallowed()
  local disallowed = { claude_disallowed_tools() }
  if not selection_allows_web() then
    disallowed[#disallowed + 1] = claude_web_disallowed_tools()
  end
  if selection_allows_shell() then
    disallowed[#disallowed + 1] = shellguard.claude_disallow_patterns()
  end
  return table.concat(disallowed, ",")
end

local function claude_review_disallowed(markdown_writes)
  local disallowed = {}
  if markdown_writes then
    disallowed[#disallowed + 1] = "NotebookEdit"
  else
    disallowed[#disallowed + 1] = claude_disallowed_tools()
  end
  if not review_allows_web() then
    disallowed[#disallowed + 1] = claude_web_disallowed_tools()
  end
  if review_allows_shell() then
    disallowed[#disallowed + 1] = shellguard.claude_disallow_patterns()
  end
  return table.concat(disallowed, ",")
end

local function claude_review_tools(markdown_writes)
  local tools = claude_read_tools({
    allow_shell = review_allows_shell(),
    allow_web = review_allows_web(),
  })
  if markdown_writes then
    tools = tools .. ",Write,Edit"
  end
  return tools
end

local function claude_plan_tools()
  local tools = claude_read_tools({
    allow_shell = true,
    allow_web = review_allows_web(),
  })
  return tools .. ",Write,Edit"
end

local function claude_plan_disallowed()
  local disallowed = { "NotebookEdit" }
  if not review_allows_web() then
    disallowed[#disallowed + 1] = claude_web_disallowed_tools()
  end
  disallowed[#disallowed + 1] = shellguard.claude_disallow_patterns()
  return table.concat(disallowed, ",")
end

local function claude_selection_tools()
  return claude_read_tools({
    allow_shell = selection_allows_shell(),
    allow_web = selection_allows_web(),
  })
end

local function claude_args(cfg, lane, prompt, run_opts)
  run_opts = run_opts or {}
  local args = {
    cfg.cmd,
    "-p",
    prompt,
    "--output-format",
    "stream-json",
    "--verbose",
    "--include-partial-messages",
    "--strict-mcp-config",
    "--exclude-dynamic-system-prompt-sections",
  }

  if run_opts.model and run_opts.model ~= "" then
    vim.list_extend(args, { "--model", run_opts.model })
  end

  -- Reasoning effort for this run. Set globally per provider
  -- (state.config.providers.claude.reasoning_effort), changed via :NvimeEffort /
  -- provider.choose_effort. The CLI flag only accepts low|medium|high|xhigh|max;
  -- "ultracode" is xhigh effort PLUS dynamic workflows, so it maps to xhigh here
  -- and the workflow half is enabled by CLAUDE_CODE_WORKFLOWS in the spawn env.
  if cfg.reasoning_effort and cfg.reasoning_effort ~= "" then
    local effort = cfg.reasoning_effort == "ultracode" and "xhigh" or cfg.reasoning_effort
    vim.list_extend(args, { "--effort", effort })
  end

  if run_opts.max_turns and run_opts.max_turns > 0 then
    vim.list_extend(args, { "--max-turns", tostring(math.floor(run_opts.max_turns)) })
  end

  if run_opts.resume_session_id and run_opts.resume_session_id ~= "" then
    vim.list_extend(args, { "--resume", run_opts.resume_session_id })
  elseif not run_opts.persist_session then
    table.insert(args, "--no-session-persistence")
  end

  if lane == "bigchange" then
    -- The "go crazy" lane: full autonomy inside an isolated git worktree
    -- (M.run sets cwd to the worktree). --dangerously-skip-permissions grants
    -- every tool with no prompts; the worktree confinement is the safety net,
    -- not the permission layer. Used by nvime.bigchange.build.
    table.insert(args, "--dangerously-skip-permissions")
  elseif lane == "review" then
    local markdown_writes = review_allows_markdown_writes()
    local tools = claude_review_tools(markdown_writes)
    local disallowed = claude_review_disallowed(markdown_writes)
    vim.list_extend(args, {
      "--permission-mode",
      "dontAsk",
      "--tools",
      tools,
      "--allowedTools",
      tools,
      "--disallowedTools",
      disallowed,
    })
  elseif lane == "plan" then
    local tools = claude_plan_tools()
    vim.list_extend(args, {
      "--permission-mode",
      "dontAsk",
      "--tools",
      tools,
      "--allowedTools",
      tools,
      "--disallowedTools",
      claude_plan_disallowed(),
    })
  elseif lane == "quick" then
    vim.list_extend(args, {
      "--permission-mode",
      "dontAsk",
      "--tools",
      "",
    })
  elseif lane == "critic" then
    -- The critic is read-only by design: it reviews a proposed patch and
    -- returns APPROVE/FLAG/REJECT. No edits, no Bash, no web — strictly
    -- inspect what's in the repo + reason about the diff in front of it.
    local tools = "Read,Glob,Grep,LS"
    vim.list_extend(args, {
      "--permission-mode",
      "dontAsk",
      "--tools",
      tools,
      "--allowedTools",
      tools,
      "--disallowedTools",
      "Edit,Write,NotebookEdit,Bash,WebFetch,WebSearch",
    })
  else
    local tools = claude_selection_tools()
    vim.list_extend(args, {
      "--permission-mode",
      "dontAsk",
      "--tools",
      tools,
      "--allowedTools",
      tools,
      "--disallowedTools",
      claude_nonreview_disallowed(),
    })
  end

  -- Inject MCP servers only for review and plan lanes where the
  -- broader tool surface (plans, attribution, test runner) helps.
  -- All other lanes skip MCP to reduce context tokens.
  if lane == "review" or lane == "plan" then
    local ok_mcp, mcp = pcall(require, "nvime.mcp")
    if ok_mcp then
      local config_path = mcp.config_path()
      if config_path then
        vim.list_extend(args, { "--mcp-config", config_path })
        -- Claude requires every MCP tool to appear in --allowedTools.
        -- Find the existing --tools / --allowedTools entries and append
        -- one mcp__<server> grant per configured server (this wildcard
        -- form covers every tool that server exposes).
        local server_grants = {}
        for name, _ in pairs(mcp.servers()) do
          server_grants[#server_grants + 1] = "mcp__" .. name
        end
        if #server_grants > 0 then
          local extra = "," .. table.concat(server_grants, ",")
          for i = 1, #args - 1 do
            if args[i] == "--tools" or args[i] == "--allowedTools" then
              args[i + 1] = args[i + 1] .. extra
            end
          end
        end
      end
    end
  end

  return args
end

local function codex_model_overrides(cfg, run_opts)
  local overrides = {}
  local model = (run_opts and run_opts.model and run_opts.model ~= "") and run_opts.model or nil
  if model then
    overrides[#overrides + 1] = "-c"
    overrides[#overrides + 1] = string.format("model=%q", model)
  end
  local effort = cfg.reasoning_effort
  if effort and effort ~= "" then
    overrides[#overrides + 1] = "-c"
    overrides[#overrides + 1] = string.format("model_reasoning_effort=%q", effort)
  end
  return overrides
end

local function codex_args(cfg, lane, _prompt, cwd, run_opts)
  run_opts = run_opts or {}
  if run_opts.resume_session_id and run_opts.resume_session_id ~= "" then
    local args = {
      cfg.cmd,
      "exec",
      "resume",
      "--json",
      "--ignore-user-config",
      "--ignore-rules",
      "--skip-git-repo-check",
    }
    vim.list_extend(args, codex_model_overrides(cfg, run_opts))
    vim.list_extend(args, { run_opts.resume_session_id, "-" })
    return args
  end

  local sandbox = "read-only"
  if lane == "bigchange" then
    -- Full autonomy confined to the worktree cwd that M.run passes via -C.
    sandbox = "workspace-write"
  elseif lane == "review" and review_allows_markdown_writes() then
    sandbox = "workspace-write"
  elseif lane == "plan" then
    -- plan lane writes plan.json/plan.md inside a temp workspace whose
    -- writable scope is .nvime/plans/<id>/. Sync-back filters non-plan paths.
    sandbox = "workspace-write"
  elseif lane == "perf" then
    -- perf lane writes scratch files under /tmp; codex's read-only sandbox
    -- forbids /tmp writes, so we elevate to workspace-write. The agent's cwd
    -- is set to a fresh /tmp directory below so this elevation cannot reach
    -- the user's repo.
    sandbox = "workspace-write"
  end
  local args = {
    cfg.cmd,
    "exec",
    "--json",
  }
  vim.list_extend(args, codex_model_overrides(cfg, run_opts))
  if not run_opts.persist_session then
    args[#args + 1] = "--ephemeral"
  end
  vim.list_extend(args, {
    "--ignore-user-config",
    "--ignore-rules",
    "--skip-git-repo-check",
    "--color",
    "never",
    "-s",
    sandbox,
    "-C",
    cwd or repo_root(),
  })

  -- Read-only enforcement parity (B2). claude restricts the read-only lanes
  -- per-tool (--disallowedTools Edit,Write,NotebookEdit + an allow-list, and
  -- drops Bash / WebFetch / WebSearch when allow_shell / allow_web are off).
  -- codex exec has no per-tool surface; it enforces read-only at the OS
  -- sandbox layer instead: `-s read-only` (review-without-markdown, critic,
  -- ask, selection, quick) forbids ALL file writes and network. Two
  -- asymmetries remain and cannot be closed from codex flags:
  --   * shell: codex still runs commands inside the read-only sandbox (they
  --     just cannot write or reach the network), so selection.allow_shell =
  --     false is advisory-only on codex, not a hard tool denial.
  --   * web: a sandboxed codex lane has no network, so allow_web = true does
  --     NOT grant it web the way claude grants WebFetch/WebSearch.
  -- For the workspace-write lanes (markdown review / plan / perf) we pin the
  -- sandbox's network access OFF explicitly so a write lane never gains
  -- incidental network and honors allow_web = false; bigchange is left as-is
  -- (its autonomy is governed by the worktree confinement, not this flag).
  if sandbox == "workspace-write" and lane ~= "bigchange" then
    vim.list_extend(args, { "-c", "sandbox_workspace_write.network_access=false" })
  end

  if lane == "bigchange" then
    -- Non-interactive full autonomy: never pause for approval. Writes stay
    -- inside the worktree cwd via the workspace-write sandbox set above.
    vim.list_extend(args, { "-c", 'approval_policy="never"' })
  end

  -- Inject MCP servers via -c overrides. Codex stores mcp_servers in
  -- config.toml; --ignore-user-config wipes the user's config so the
  -- overrides we pass become the entire MCP namespace. Same servers
  -- claude sees via --mcp-config. Codex still auto-cancels MCP tool
  -- calls in non-interactive exec mode unless the explicit bypass flag
  -- below is enabled.
  -- Only review and plan lanes get MCP tools (plans, attribution,
  -- test runner). All other lanes skip MCP to reduce context tokens.
  if lane == "review" or lane == "plan" then
    local ok_mcp, mcp = pcall(require, "nvime.mcp")
    if ok_mcp then
      local servers = mcp.servers() or {}
      local has_servers = false
      for name, entry in pairs(servers) do
        if type(entry) == "table" and entry.command then
          has_servers = true
          local prefix = "mcp_servers." .. name
          local function toml_string(s)
            return string.format("%q", tostring(s))
          end
          vim.list_extend(args, { "-c", prefix .. ".command=" .. toml_string(entry.command) })
          if type(entry.args) == "table" and #entry.args > 0 then
            local quoted = {}
            for _, a in ipairs(entry.args) do
              quoted[#quoted + 1] = toml_string(a)
            end
            vim.list_extend(args, { "-c", prefix .. ".args=[" .. table.concat(quoted, ",") .. "]" })
          end
          if type(entry.env) == "table" then
            for k, v in pairs(entry.env) do
              vim.list_extend(args, { "-c", prefix .. ".env." .. k .. "=" .. toml_string(v) })
            end
          end
        end
      end
      if has_servers then
        vim.list_extend(args, { "-c", 'approval_policy="never"' })
        -- Codex auto-cancels MCP tool calls in `exec` mode unless we set
        -- this flag, which also turns off codex's OS-level sandbox.
        -- Gated behind explicit config so users opt-in knowingly.
        local mcp_cfg = (state.config or {}).mcp or {}
        if mcp_cfg.codex_bypass_for_mcp == true then
          args[#args + 1] = "--dangerously-bypass-approvals-and-sandbox"
        end
      end
    end
  end

  return args
end

local function build_args(provider, cfg, lane, prompt, cwd, run_opts)
  if provider == "claude" then
    return claude_args(cfg, lane, prompt, run_opts)
  end
  if provider == "codex" then
    return codex_args(cfg, lane, prompt, cwd, run_opts)
  end
  error("No adapter for provider: " .. provider)
end

local excluded_workspace_dirs = {
  [".git"] = true,
  [".nvime"] = true,
  ["node_modules"] = true,
  [".direnv"] = true,
  [".venv"] = true,
  ["__pycache__"] = true,
}

local plan_excluded_workspace_dirs = {
  [".git"] = true,
  ["node_modules"] = true,
  [".direnv"] = true,
  [".venv"] = true,
  ["__pycache__"] = true,
}

local function mkdir_p(path)
  vim.fn.mkdir(path, "p")
end

local function normalize_dir(path)
  local normalized = vim.fn.fnamemodify(path, ":p")
  if #normalized > 1 then
    normalized = normalized:gsub("/+$", "")
  end
  return normalized
end

local function ensure_workspace_git_root(path)
  if not path or path == "" or vim.fn.isdirectory(path .. "/.git") == 1 then
    return
  end
  pcall(vim.fn.system, { "git", "-C", path, "init", "-q" })
end

local function copy_file(src, dst)
  mkdir_p(vim.fn.fnamemodify(dst, ":h"))
  if uv and uv.fs_copyfile then
    local ok = pcall(uv.fs_copyfile, src, dst)
    if ok then
      return
    end
  end
  vim.fn.writefile(vim.fn.readfile(src, "b"), dst, "b")
end

local function copy_tree(src, dst, excluded)
  excluded = excluded or excluded_workspace_dirs
  mkdir_p(dst)
  local scanner = uv.fs_scandir(src)
  if not scanner then
    return
  end
  while true do
    local name, kind = uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    local source = src .. "/" .. name
    local target = dst .. "/" .. name
    if kind == "directory" and not excluded[name] then
      copy_tree(source, target, excluded)
    elseif kind == "file" then
      copy_file(source, target)
    end
  end
end

local function copy_plans_into_workspace(root, cwd)
  local src = root .. "/.nvime/plans"
  if vim.fn.isdirectory(src) ~= 1 then
    return
  end
  local dst = cwd .. "/.nvime/plans"
  copy_tree(src, dst, plan_excluded_workspace_dirs)
end

local function is_markdown(path)
  local lower = path:lower()
  return lower:match("%.md$") ~= nil or lower:match("%.markdown$") ~= nil
end

local function same_file(a, b)
  if vim.fn.filereadable(a) == 0 or vim.fn.filereadable(b) == 0 then
    return false
  end
  if vim.fn.getfsize(a) ~= vim.fn.getfsize(b) then
    return false
  end
  return table.concat(vim.fn.readfile(a, "b"), "\n") == table.concat(vim.fn.readfile(b, "b"), "\n")
end

local function collect_markdown(root, base, out)
  local scanner = uv.fs_scandir(root)
  if not scanner then
    return
  end
  while true do
    local name, kind = uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    local path = root .. "/" .. name
    local rel = base == "" and name or (base .. "/" .. name)
    if kind == "directory" and not excluded_workspace_dirs[name] then
      collect_markdown(path, rel, out)
    elseif kind == "file" and is_markdown(rel) then
      out[#out + 1] = rel
    end
  end
end

local function collect_plan_files(root, base, out)
  local scanner = uv.fs_scandir(root)
  if not scanner then
    return
  end
  while true do
    local name, kind = uv.fs_scandir_next(scanner)
    if not name then
      break
    end
    local path = root .. "/" .. name
    local rel = base == "" and name or (base .. "/" .. name)
    if kind == "directory" then
      collect_plan_files(path, rel, out)
    elseif kind == "file" then
      out[#out + 1] = rel
    end
  end
end

-- A filesystem-safe, repo-specific id so two checkouts don't share a workspace.
local function plan_workspace_slug(root)
  local base = vim.fn.fnamemodify(root, ":t")
  if base == nil or base == "" then
    base = "repo"
  end
  local hash = vim.fn.sha256 and vim.fn.sha256(root):sub(1, 8) or tostring(#root)
  return (base:gsub("[^%w%-_]", "_")) .. "-" .. hash
end

local function prepare_plan_workspace(lane)
  if lane ~= "plan" then
    return nil
  end
  local root = repo_root()
  -- STABLE workspace path (NOT a fresh tempname). claude/codex key resumable
  -- sessions by project directory, so a plan-author session can only be resumed
  -- on a later refine/update if the cwd is identical. We therefore keep one
  -- workspace per repo under stdpath('data') and refresh its contents each run.
  -- (Returning no `tmp` keeps the dispatcher from deleting it after the run; the
  -- provider's session store lives in ~/.claude, not here, so wiping the
  -- contents to re-mirror the repo never invalidates the session.)
  local cwd = string.format("%s/nvime/plan-workspace/%s/workspace", vim.fn.stdpath("data"), plan_workspace_slug(root))
  pcall(vim.fn.delete, cwd, "rf")
  copy_tree(root, cwd, plan_excluded_workspace_dirs)
  -- copy_tree above intentionally excludes the .git tree; everything else
  -- including .nvime/plans is now in the workspace. .nvime/plans gets a
  -- mirror so the agent can refine prior plans.
  copy_plans_into_workspace(root, cwd)
  ensure_workspace_git_root(cwd)
  return {
    root = root,
    cwd = cwd,
    lane = lane,
  }
end

local function sync_plan_workspace(workspace)
  if not workspace or workspace.lane ~= "plan" then
    return {}
  end
  local rels = {}
  local plan_dir = workspace.cwd .. "/.nvime/plans"
  if vim.fn.isdirectory(plan_dir) == 1 then
    collect_plan_files(plan_dir, ".nvime/plans", rels)
  end
  table.sort(rels)

  local synced = {}
  for _, rel in ipairs(rels) do
    local source = workspace.cwd .. "/" .. rel
    local target = workspace.root .. "/" .. rel
    if vim.fn.filereadable(source) == 1 and not same_file(source, target) then
      copy_file(source, target)
      synced[#synced + 1] = rel
    end
  end
  return synced
end

local function prepare_markdown_workspace(lane, allow_workspace, requested_workspace)
  if allow_workspace == false or lane ~= "review" or not review_allows_markdown_writes() then
    return nil
  end
  local root = repo_root()
  if requested_workspace and requested_workspace ~= "" then
    local cwd = normalize_dir(requested_workspace)
    mkdir_p(cwd)
    copy_tree(root, cwd)
    ensure_workspace_git_root(cwd)
    return {
      root = root,
      cwd = cwd,
      persist = true,
    }
  end

  local tmp = vim.fn.tempname()
  local cwd = tmp .. "/workspace"
  copy_tree(root, cwd)
  ensure_workspace_git_root(cwd)
  return {
    root = root,
    tmp = tmp,
    cwd = cwd,
  }
end

local function cleanup_workspace(workspace)
  if workspace and workspace.persist then
    return
  end
  if workspace and workspace.tmp and workspace.tmp ~= "" then
    pcall(vim.fn.delete, workspace.tmp, "rf")
  end
end

local function sync_markdown_workspace(workspace)
  if not workspace then
    return {}
  end
  local rels = {}
  collect_markdown(workspace.cwd, "", rels)
  table.sort(rels)

  local synced = {}
  for _, rel in ipairs(rels) do
    local source = workspace.cwd .. "/" .. rel
    local target = workspace.root .. "/" .. rel
    if vim.fn.filereadable(source) == 1 and not same_file(source, target) then
      copy_file(source, target)
      synced[#synced + 1] = rel
    end
  end
  return synced
end

local function tool_detail(input)
  if type(input) ~= "table" then
    return ""
  end
  return input.command
    or input.file_path
    or input.pattern
    or input.path
    or input.description
    or input.uri
    or input.symbol
    or input.query
    or input.name
    or input.action
    or input.method
    or input.lsp_method
    or ""
end

local function tool_progress(provider, name, input)
  name = name or "tool"
  local detail = tool_detail(input)
  if detail ~= "" then
    return "[" .. provider .. "] tool: " .. vim.trim(name .. ": " .. tostring(detail)) .. "\n"
  end
  return "[" .. provider .. "] tool: " .. tostring(name) .. "\n"
end

local function parse_claude(line)
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok or type(decoded) ~= "table" then
    return { text = line .. "\n" }
  end

  local session_id = decoded.session_id
  local function attach_session(parsed)
    parsed = parsed or {}
    if session_id and session_id ~= "" then
      parsed.session_id = session_id
    end
    return parsed
  end

  local event = decoded.event or {}
  local delta = event.delta or decoded.delta or {}
  if delta.type == "text_delta" and delta.text then
    return attach_session({ text = delta.text, text_kind = "delta" })
  end

  if decoded.type == "assistant" and decoded.message and type(decoded.message.content) == "table" then
    local text_parts = {}
    local progress = {}
    for _, block in ipairs(decoded.message.content) do
      if block.type == "text" and block.text and block.text ~= "" then
        text_parts[#text_parts + 1] = block.text
      elseif block.type == "tool_use" then
        progress[#progress + 1] = tool_progress("claude", block.name, block.input):gsub("\n$", "")
      end
    end
    if #text_parts > 0 then
      return attach_session({ text = table.concat(text_parts, "\n"), text_kind = "aggregate" })
    end
    if #progress > 0 then
      return attach_session({ progress = table.concat(progress, "\n") .. "\n" })
    end
  end

  if event.type == "content_block_start" and event.content_block and event.content_block.type == "tool_use" then
    return attach_session({ progress = tool_progress("claude", event.content_block.name, event.content_block.input) })
  end

  if decoded.type == "system" and decoded.subtype == "init" then
    return attach_session({ progress = "[claude] session started\n" })
  end

  if decoded.type == "result" then
    local sample = usage.parse_claude(decoded)
    if sample then
      return attach_session({ usage = sample })
    end
  end

  return session_id and attach_session({}) or nil
end

local function parse_codex(line)
  if line:match("^Reading prompt from stdin") or line:match("^Reading additional input from stdin") then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, line)
  if not ok or type(decoded) ~= "table" then
    return { text = line .. "\n" }
  end

  local session_id = decoded.session_id or decoded.conversation_id or decoded.thread_id
  if not session_id and type(decoded.session) == "table" then
    session_id = decoded.session.id or decoded.session.session_id
  end
  local function out(parsed)
    parsed = parsed or {}
    if session_id and session_id ~= "" then
      parsed.session_id = session_id
    end
    return parsed
  end

  local item = decoded.item
  if type(item) == "table" then
    if item.type == "agent_message" and item.text then
      return out({ text = item.text, text_kind = "aggregate" })
    end
    if item.type == "reasoning" and item.summary then
      if type(item.summary) == "table" then
        local summary = {}
        for _, part in ipairs(item.summary) do
          if type(part) == "string" then
            summary[#summary + 1] = part
          elseif type(part) == "table" and part.text then
            summary[#summary + 1] = part.text
          end
        end
        if #summary > 0 then
          return out({ progress = "[codex] " .. table.concat(summary, "\n[codex] ") .. "\n" })
        end
      elseif item.summary ~= "" then
        return out({ progress = "[codex] " .. tostring(item.summary) .. "\n" })
      end
    end
    if item.type == "command_execution" or item.type == "tool_call" or item.type == "function_call" then
      local detail = item.command or item.name or item.title or item.call_id or "tool"
      if type(detail) == "table" then
        detail = table.concat(detail, " ")
      end
      return out({ progress = "[codex] tool: " .. tostring(detail) .. "\n" })
    end
  end

  if decoded.type == "turn.started" then
    return out({ progress = "[codex] working\n" })
  end
  if decoded.type == "item.started" and type(item) == "table" then
    return out({ progress = "[codex] " .. tostring(item.type or "item") .. "\n" })
  end
  if decoded.type == "error" and decoded.message then
    return out({ text = "\n[error] " .. decoded.message .. "\n" })
  end
  if decoded.type == "turn.failed" and decoded.error then
    return out({ text = "\n[failed] " .. tostring(decoded.error) .. "\n" })
  end
  if decoded.type == "turn.completed" then
    local sample = usage.parse_codex(decoded)
    if sample then
      return out({ usage = sample })
    end
  end
  return session_id and out({}) or nil
end

local function parser_for(provider)
  if provider == "claude" then
    return parse_claude
  end
  if provider == "codex" then
    return parse_codex
  end
  return function(line)
    return line .. "\n"
  end
end

local function is_provider_noise(provider, line)
  if provider == "codex" then
    return line:find("codex_models_manager::manager: failed to refresh available models", 1, true) ~= nil
  end
  return false
end

local function consume_chunks(provider, on_text, on_progress, on_session_id, opts)
  opts = opts or {}
  local on_usage = opts.on_usage or function() end
  local parse = parser_for(provider)
  local pending = ""
  local last_progress = nil
  local emitted_text = ""
  local function dedupe_text(parsed)
    local text = parsed.text
    if not text or text == "" then
      return nil
    end
    if parsed.text_kind == "aggregate" and emitted_text ~= "" then
      if text == emitted_text then
        return nil
      end
      if text:sub(1, #emitted_text) == emitted_text then
        local tail = text:sub(#emitted_text + 1)
        emitted_text = text
        if tail == "" then
          return nil
        end
        return tail
      end
      if #text < #emitted_text and emitted_text:sub(-#text) == text then
        return nil
      end
    end
    emitted_text = emitted_text .. text
    return text
  end
  local function emit(parsed)
    if not parsed then
      return
    end
    if type(parsed) == "string" then
      on_text(parsed)
      return
    end
    if parsed.session_id and parsed.session_id ~= "" then
      on_session_id(parsed.session_id)
    end
    if parsed.text and parsed.text ~= "" then
      local text = dedupe_text(parsed)
      if text and text ~= "" then
        on_text(text)
      end
    end
    if parsed.progress and parsed.progress ~= "" then
      if parsed.progress ~= last_progress then
        last_progress = parsed.progress
        on_progress(parsed.progress)
      end
    end
    if parsed.usage then
      on_usage(parsed.usage)
    end
  end
  return function(_err, data)
    if not data or data == "" then
      return
    end
    pending = pending .. data
    while true do
      local idx = pending:find("\n", 1, true)
      if not idx then
        break
      end
      local line = pending:sub(1, idx - 1)
      pending = pending:sub(idx + 1)
      if not (opts.stderr and is_provider_noise(provider, line)) then
        emit(parse(line))
      end
    end
  end, function()
    if pending ~= "" then
      local parsed = nil
      if not (opts.stderr and is_provider_noise(provider, pending)) then
        parsed = parse(pending)
      end
      pending = ""
      emit(parsed)
    end
  end
end

-- Per-run wall-clock timeout (ms) for a lane, or nil when unbounded. A
-- lane-specific value wins over the global agents.timeout_ms.
local function resolve_timeout(lane)
  local cfg = (state.config or {}).agents or {}
  local value = tonumber((cfg.lane_timeouts or {})[lane]) or tonumber(cfg.timeout_ms)
  if value and value > 0 then
    return value
  end
  return nil
end

M._resolve_timeout = resolve_timeout
M._claude_args = claude_args
M._codex_args = codex_args

function M.run(opts)
  opts = opts or {}
  if state.disabled then
    vim.schedule(function()
      vim.notify("nvime is disabled; run :NvimeEnable to re-enable it", vim.log.levels.WARN)
    end)
    return nil
  end
  local provider, cfg = provider_config(opts.provider)
  local lane = opts.lane or "review"
  local timeout_ms = resolve_timeout(lane)
  local prompt = opts.prompt or ""
  local input = opts.input
  local on_text = opts.on_text or function() end
  local on_progress = opts.on_progress or function() end
  local on_session_id = opts.on_session_id or function() end
  local on_exit = opts.on_exit or function() end
  local run_opts = {
    persist_session = opts.persist_session == true,
    resume_session_id = opts.resume_session_id,
    model = opts.model,
    max_turns = opts.max_turns,
  }
  local workspace = prepare_markdown_workspace(lane, opts.allow_markdown_workspace, opts.markdown_workspace)
  local plan_workspace = prepare_plan_workspace(lane)
  local perf_workspace = nil
  if lane == "perf" and provider == "codex" then
    -- Empty scratch cwd outside the repo so codex's workspace-write sandbox
    -- can never escalate into the user's working tree.
    local tmp = vim.fn.tempname() .. "/perf"
    vim.fn.mkdir(tmp, "p")
    perf_workspace = { cwd = tmp, tmp = vim.fn.fnamemodify(tmp, ":h") }
  end
  local cwd = opts.cwd
    or (perf_workspace and perf_workspace.cwd)
    or (plan_workspace and plan_workspace.cwd)
    or (workspace and workspace.cwd)
    or repo_root()
  -- Bind every spawned agent to the project's CLAUDE.md (see with_project_guidance).
  local effective_prompt = with_project_guidance(prompt, opts)
  local guidance_injected = effective_prompt ~= prompt
  local args = build_args(provider, cfg, lane, effective_prompt, cwd, run_opts)
  local stdin = input
  if provider == "codex" then
    stdin = effective_prompt
    if input and input ~= "" then
      stdin = effective_prompt .. "\n\n<context>\n" .. input .. "\n</context>\n"
    end
  end
  local drain
  local observed_session_id = opts.resume_session_id
  local function handle_session_id(session_id)
    if session_id and session_id ~= "" then
      observed_session_id = session_id
      on_session_id(session_id)
    end
  end
  local observed_usage = nil
  local function handle_usage(sample)
    if not sample then
      return
    end
    if not observed_usage then
      observed_usage = sample
      return
    end
    -- Multiple result events in one run (claude follow-on turns) — sum.
    observed_usage.input = (observed_usage.input or 0) + (sample.input or 0)
    observed_usage.output = (observed_usage.output or 0) + (sample.output or 0)
    observed_usage.cache_read = (observed_usage.cache_read or 0) + (sample.cache_read or 0)
    observed_usage.cache_creation = (observed_usage.cache_creation or 0) + (sample.cache_creation or 0)
    observed_usage.reasoning = (observed_usage.reasoning or 0) + (sample.reasoning or 0)
    observed_usage.cost_usd = (observed_usage.cost_usd or 0) + (sample.cost_usd or 0)
    observed_usage.model = sample.model or observed_usage.model
  end
  local stdout, drain_stdout =
    consume_chunks(provider, on_text, on_progress, handle_session_id, { on_usage = handle_usage })
  local stderr, drain_stderr = consume_chunks(provider, function(text)
    on_text(text)
  end, on_progress, handle_session_id, { stderr = true, on_usage = handle_usage })
  drain = function()
    drain_stdout()
    drain_stderr()
  end

  audit.write({
    event = "agent_start",
    lane = lane,
    provider = provider,
    tool = args[1],
    argv = table.concat(args, " "),
    cwd = cwd,
    markdown_workspace = workspace and workspace.cwd or nil,
    persist_session = run_opts.persist_session,
    resume_session_id = run_opts.resume_session_id,
    timeout_ms = timeout_ms,
    prompt = prompt,
    project_guidance = guidance_injected,
    input = stdin,
  })
  on_progress("[nvime] " .. provider .. " started (" .. lane .. ")\n")

  local spawn_env = shellguard.build_env()
  -- Ultracode = xhigh effort (passed via --effort in claude_args) + Claude Code's
  -- dynamic workflow orchestration. This env var is the workflows half — the same
  -- toggle interactive `/effort ultracode` flips. Lets a claude agent spawn
  -- sub-agent workflows for complex tasks (more tokens; opt-in per the effort UI).
  if provider == "claude" and cfg.reasoning_effort == "ultracode" then
    spawn_env.CLAUDE_CODE_WORKFLOWS = "1"
  end

  return policy.with_trusted(function()
    local system_opts = {
      text = true,
      stdout = stdout,
      stderr = stderr,
      cwd = cwd,
      env = spawn_env,
      -- vim.system kills the process (SIGTERM) and reports code 124 on timeout;
      -- nil leaves the run unbounded (the default).
      timeout = timeout_ms,
    }
    if stdin ~= nil then
      system_opts.stdin = stdin
    end

    local spawn_ok, handle = pcall(vim.system, args, system_opts, function(result)
      drain()
      vim.schedule(function()
        local synced = sync_markdown_workspace(workspace)
        local synced_plans = sync_plan_workspace(plan_workspace)
        -- Codex turn.completed reports cumulative session usage, not per-turn.
        -- Compute the per-turn delta by subtracting the previous cumulative.
        local on_cumulative_usage = opts.on_cumulative_usage or function() end
        if observed_usage and provider == "codex" then
          local prev = opts.previous_cumulative_usage
          -- Store the raw cumulative for next run's subtraction.
          on_cumulative_usage({
            input = (observed_usage.input or 0) + (observed_usage.cache_read or 0),
            output = (observed_usage.output or 0),
            cache_read = (observed_usage.cache_read or 0),
            reasoning = (observed_usage.reasoning or 0),
          })
          if prev then
            observed_usage.input = math.max(0, (observed_usage.input or 0) - (prev.input or 0) + (prev.cache_read or 0))
            observed_usage.output = math.max(0, (observed_usage.output or 0) - (prev.output or 0))
            observed_usage.cache_read = math.max(0, (observed_usage.cache_read or 0) - (prev.cache_read or 0))
            observed_usage.reasoning = math.max(0, (observed_usage.reasoning or 0) - (prev.reasoning or 0))
            observed_usage.cost_usd = 0
          end
        end
        local recorded_usage
        if observed_usage then
          recorded_usage = usage.record({
            sample = observed_usage,
            provider = provider,
            lane = lane,
          })
        end
        -- vim.system reports code 124 when our configured timeout fired (a
        -- distinct value from a clean exit or a user cancel), so a bounded run
        -- that overran is recorded as its own reviewable event.
        local timed_out = timeout_ms ~= nil and result.code == 124
        if timed_out then
          audit.write({
            event = "agent_timeout",
            lane = lane,
            provider = provider,
            timeout_ms = timeout_ms,
          })
          vim.notify(
            string.format("nvime: %s %s run exceeded its %dms timeout and was stopped", provider, lane, timeout_ms),
            vim.log.levels.WARN
          )
        end
        audit.write({
          event = "agent_exit",
          lane = lane,
          provider = provider,
          tool = args[1],
          code = result.code,
          signal = result.signal,
          timed_out = timed_out,
          timeout_ms = timeout_ms,
          provider_session_id = observed_session_id,
          synced_markdown = synced,
          synced_plan_files = synced_plans,
          usage = observed_usage,
        })
        result.nvime_timed_out = timed_out
        result.nvime_synced_markdown = synced
        result.nvime_synced_plan_files = synced_plans
        result.nvime_provider_session_id = observed_session_id
        result.nvime_usage = observed_usage
        result.nvime_usage_record = recorded_usage
        local ok, err = pcall(on_exit, result)
        cleanup_workspace(workspace)
        if plan_workspace and plan_workspace.tmp then
          pcall(vim.fn.delete, plan_workspace.tmp, "rf")
        end
        if perf_workspace and perf_workspace.tmp then
          pcall(vim.fn.delete, perf_workspace.tmp, "rf")
        end
        if not ok then
          error(err)
        end
      end)
    end)
    if not spawn_ok then
      -- vim.system throws synchronously when args[1] (the provider binary) is
      -- not on PATH, or when cwd no longer exists. Without this guard the throw
      -- escapes M.run: the exit callback never fires, so the markdown/plan/perf
      -- temp workspaces leak AND — because callers set busy state before the
      -- call and clear it only from on_exit — the session is wedged "busy"
      -- forever (spinner never stops). Mirror the exit-path cleanup and deliver
      -- a synthetic failure result so the caller resets its state.
      local spawn_err = handle
      vim.schedule(function()
        cleanup_workspace(workspace)
        if plan_workspace and plan_workspace.tmp then
          pcall(vim.fn.delete, plan_workspace.tmp, "rf")
        end
        if perf_workspace and perf_workspace.tmp then
          pcall(vim.fn.delete, perf_workspace.tmp, "rf")
        end
        audit.write({
          event = "agent_exit",
          lane = lane,
          provider = provider,
          tool = args[1],
          code = -1,
          spawn_error = tostring(spawn_err),
        })
        vim.notify(
          string.format("nvime: could not start %s (%s lane): %s", provider, lane, tostring(spawn_err)),
          vim.log.levels.ERROR
        )
        pcall(on_exit, { code = -1, signal = 0, stdout = "", stderr = tostring(spawn_err) })
      end)
      return nil
    end
    if type(opts.on_handle) == "function" then
      local ok, err = pcall(opts.on_handle, handle)
      if not ok then
        vim.schedule(function()
          vim.notify("nvime could not store agent handle: " .. tostring(err), vim.log.levels.WARN)
        end)
      end
    end
    return handle
  end)
end

return M
