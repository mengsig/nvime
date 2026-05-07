local agents = require("nvime.agents")
local chat = require("nvime.chat")
local git = require("nvime.git")

local M = {}

local function git_diff(args)
  local cwd = (vim.uv or vim.loop).cwd()
  local cmd =
    { "git", "-C", cwd, "diff", "--no-ext-diff", "--no-color", "--find-renames", "--find-copies", "--unified=80" }
  vim.list_extend(cmd, args or {})
  return table.concat(git.systemlist(cmd), "\n")
end

function M.start(opts)
  opts = opts or {}
  local provider = opts.provider or require("nvime.state").config.provider
  local prompt = opts.prompt
  if not prompt or prompt == "" then
    prompt =
      "Review the current repository state. Be concrete, prioritize bugs and behavioral regressions. You may use shell commands including curl and web fetch/search tools when available. You may create or update Markdown documentation files only; do not edit source/config files."
  end

  local input = opts.input
  if not input and opts.diff ~= false then
    input = git_diff(opts.cached and { "--cached" } or {})
  end

  chat.open()
  local session_id = chat.active_session_id()
  chat.append("\n\n[" .. provider .. " review]$ " .. prompt .. "\n\n", session_id)
  chat.append("[" .. provider .. " response]\n" .. string.rep("-", 78) .. "\n\n", session_id)
  chat.set_busy(true, session_id)
  local agent_session = chat.agent_run_opts(provider, session_id)
  local handle
  handle = agents.run({
    provider = provider,
    lane = "review",
    prompt = prompt,
    input = input,
    persist_session = agent_session.persist_session,
    resume_session_id = agent_session.resume_session_id,
    markdown_workspace = agent_session.markdown_workspace,
    on_session_id = agent_session.on_session_id,
    on_text = function(text)
      chat.append(text, session_id)
    end,
    on_progress = function(text)
      chat.set_progress(text, session_id)
    end,
    on_handle = function(agent_handle)
      handle = agent_handle
      chat.attach_process(session_id, agent_handle)
    end,
    on_exit = function(result)
      local session = chat.get_session(session_id)
      local cancelled = session
        and (
          (handle and session.cancelled_handles and session.cancelled_handles[handle] == true)
          or (not handle and session.cancelled == true)
        )
      if session and handle and session.cancelled_handles then
        session.cancelled_handles[handle] = nil
      end
      chat.clear_process(session_id, handle)
      chat.set_busy(false, session_id)
      if session and cancelled then
        session.cancelled = false
      end
      if cancelled then
        return
      end
      local synced = result.nvime_synced_markdown or {}
      if #synced > 0 then
        vim.notify("nvime synced markdown: " .. table.concat(synced, ", "), vim.log.levels.INFO)
      end
      if result.code ~= 0 then
        chat.append("\n[nvime] review failed with code " .. tostring(result.code) .. "\n", session_id)
      end
    end,
  })
  if not handle then
    chat.set_busy(false, session_id)
  end
end

return M
