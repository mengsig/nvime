local audit = require("nvime.audit")
local git = require("nvime.git")
local policy = require("nvime.policy")
local state = require("nvime.state")

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
  return "Edit,Write,MultiEdit,NotebookEdit"
end

local function claude_web_disallowed_tools()
  return "WebFetch,WebSearch"
end

local function claude_nonreview_disallowed()
  local disallowed = { claude_disallowed_tools() }
  if not selection_allows_web() then
    disallowed[#disallowed + 1] = claude_web_disallowed_tools()
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
  return table.concat(disallowed, ",")
end

local function claude_review_tools(markdown_writes)
  local tools = claude_read_tools({
    allow_shell = review_allows_shell(),
    allow_web = review_allows_web(),
  })
  if markdown_writes then
    tools = tools .. ",Write,Edit,MultiEdit"
  end
  return tools
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
  }

  if run_opts.resume_session_id and run_opts.resume_session_id ~= "" then
    vim.list_extend(args, { "--resume", run_opts.resume_session_id })
  elseif not run_opts.persist_session then
    table.insert(args, "--no-session-persistence")
  end

  if lane == "review" then
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

  return args
end

local function codex_args(cfg, lane, _prompt, cwd, run_opts)
  run_opts = run_opts or {}
  if run_opts.resume_session_id and run_opts.resume_session_id ~= "" then
    return {
      cfg.cmd,
      "exec",
      "resume",
      "--json",
      "--ignore-user-config",
      "--ignore-rules",
      "--skip-git-repo-check",
      run_opts.resume_session_id,
      "-",
    }
  end

  local sandbox = "read-only"
  if lane == "review" and review_allows_markdown_writes() then
    sandbox = "workspace-write"
  end
  local args = {
    cfg.cmd,
    "exec",
    "--json",
  }
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

local function copy_tree(src, dst)
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
    if kind == "directory" and not excluded_workspace_dirs[name] then
      copy_tree(source, target)
    elseif kind == "file" then
      copy_file(source, target)
    end
  end
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

function M.run(opts)
  local provider, cfg = provider_config(opts.provider)
  local lane = opts.lane or "review"
  local prompt = opts.prompt or ""
  local input = opts.input
  local on_text = opts.on_text or function() end
  local on_progress = opts.on_progress or function() end
  local on_session_id = opts.on_session_id or function() end
  local on_exit = opts.on_exit or function() end
  local run_opts = {
    persist_session = opts.persist_session == true,
    resume_session_id = opts.resume_session_id,
  }
  local workspace = prepare_markdown_workspace(lane, opts.allow_markdown_workspace, opts.markdown_workspace)
  local cwd = workspace and workspace.cwd or repo_root()
  local args = build_args(provider, cfg, lane, prompt, cwd, run_opts)
  local stdin = input
  if provider == "codex" then
    stdin = prompt
    if input and input ~= "" then
      stdin = prompt .. "\n\n<context>\n" .. input .. "\n</context>\n"
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
  local stdout, drain_stdout = consume_chunks(provider, on_text, on_progress, handle_session_id)
  local stderr, drain_stderr = consume_chunks(provider, function(text)
    on_text(text)
  end, on_progress, handle_session_id, { stderr = true })
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
    prompt = prompt,
    input = stdin,
  })
  on_progress("[nvime] " .. provider .. " started (" .. lane .. ")\n")

  return policy.with_trusted(function()
    local system_opts = {
      text = true,
      stdout = stdout,
      stderr = stderr,
      cwd = cwd,
    }
    if stdin ~= nil then
      system_opts.stdin = stdin
    end

    return vim.system(args, system_opts, function(result)
      drain()
      vim.schedule(function()
        local synced = sync_markdown_workspace(workspace)
        audit.write({
          event = "agent_exit",
          lane = lane,
          provider = provider,
          tool = args[1],
          code = result.code,
          signal = result.signal,
          provider_session_id = observed_session_id,
          synced_markdown = synced,
        })
        result.nvime_synced_markdown = synced
        result.nvime_provider_session_id = observed_session_id
        local ok, err = pcall(on_exit, result)
        cleanup_workspace(workspace)
        if not ok then
          error(err)
        end
      end)
    end)
  end)
end

return M
