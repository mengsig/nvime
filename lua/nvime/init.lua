local config = require("nvime.config")
local policy = require("nvime.policy")
local provider = require("nvime.provider")
local state = require("nvime.state")

local M = {}

local persist_group = vim.api.nvim_create_augroup("nvime.persist", { clear = false })
local audit_group = vim.api.nvim_create_augroup("nvime.audit", { clear = false })

local function delete_keymaps()
  for _, keymap in ipairs(state.keymaps or {}) do
    pcall(vim.keymap.del, keymap.mode, keymap.lhs)
  end
  state.keymaps = {}
end

local function set_keymap(mode, lhs, rhs, desc)
  if not lhs or lhs == "" then
    return
  end
  vim.keymap.set(mode, lhs, rhs, {
    desc = desc,
    silent = true,
  })
  state.keymaps[#state.keymaps + 1] = {
    mode = mode,
    lhs = lhs,
  }
end

local function visual_edit()
  vim.cmd.normal({ args = { "\27" }, bang = true })
  local line1 = vim.fn.line("'<")
  local line2 = vim.fn.line("'>")
  if line1 > line2 then
    line1, line2 = line2, line1
  end
  require("nvime.edit").start({
    line1 = line1,
    line2 = line2,
    range = 2,
    choose_session = true,
  })
end

local function visual_ask()
  vim.cmd.normal({ args = { "\27" }, bang = true })
  local line1 = vim.fn.line("'<")
  local line2 = vim.fn.line("'>")
  if line1 > line2 then
    line1, line2 = line2, line1
  end
  require("nvime.ask").start({
    line1 = line1,
    line2 = line2,
    range = 2,
    choose_session = true,
  })
end

function M.open_last()
  local chat = require("nvime.chat")
  local selection = require("nvime.selection")
  local last = state.last_session
  if last and last.kind == "chat" and chat.get_session(last.id) then
    chat.open_session(last.id)
    return
  end
  if last and last.kind == "selection" and selection.get_session(last.id) then
    selection.open_session(last.id)
    return
  end

  local latest = nil
  local latest_kind = nil
  for _, session in ipairs(chat.sessions()) do
    if not latest or (session.updated_at or 0) > (latest.updated_at or 0) then
      latest = session
      latest_kind = "chat"
    end
  end
  for _, session in ipairs(selection.sessions()) do
    if not latest or (session.updated_at or 0) > (latest.updated_at or 0) then
      latest = session
      latest_kind = "selection"
    end
  end

  if latest_kind == "chat" then
    chat.open_session(latest.id)
  elseif latest_kind == "selection" then
    selection.open_session(latest.id)
  else
    vim.notify("No nvime conversation to reopen", vim.log.levels.INFO)
  end
end

function M.statusline()
  local ok_chat, chat = pcall(require, "nvime.chat")
  local ok_selection, selection = pcall(require, "nvime.selection")
  if not ok_chat or not ok_selection then
    return "nvime"
  end
  local chat_sessions = chat.sessions()
  local selection_sessions = selection.sessions()
  local running = 0
  for _, session in ipairs(chat_sessions) do
    if session.busy then
      running = running + 1
    end
  end
  for _, session in ipairs(selection_sessions) do
    if session.busy then
      running = running + 1
    end
  end
  local total = #chat_sessions + #selection_sessions
  local plan_label = ""
  local ok_plan, plan = pcall(require, "nvime.plan")
  if ok_plan then
    local components = plan.statusline_components()
    if components and components.total and components.total > 0 then
      if components.in_progress > 0 then
        plan_label = string.format(" plans %d⇢", components.in_progress)
      else
        plan_label = string.format(" plans %d", components.total)
      end
    end
  end
  if running > 0 then
    return string.format("nvime %d/%d running%s", running, total, plan_label)
  end
  return string.format("nvime %d%s", total, plan_label)
end

local function install_keymaps()
  delete_keymaps()

  local keys = state.config.keys or {}
  if keys.enabled == false then
    return
  end

  local prefix = keys.prefix or "<leader>n"
  local normal = keys.normal or {}
  local visual = keys.visual or {}

  set_keymap("n", prefix .. (normal.dashboard or "<Space>"), "<Cmd>Nvime<CR>", "nvime dashboard")
  set_keymap("n", prefix .. (normal.chat or "c"), "<Cmd>NvimeChat<CR>", "nvime chat conversations")
  set_keymap("n", prefix .. (normal.review or "r"), "<Cmd>NvimeReview<CR>", "nvime review/docs")
  set_keymap("n", prefix .. (normal.edit or "e"), "<Cmd>NvimeChats edit<CR>", "nvime edit discussions")
  set_keymap("n", prefix .. (normal.ask or "q"), "<Cmd>NvimeChats ask<CR>", "nvime ask discussions")
  set_keymap("n", prefix .. (normal.audit or "a"), "<Cmd>NvimeAudit<CR>", "nvime audit log")
  set_keymap("n", prefix .. (normal.discuss or "d"), function()
    require("nvime.edit").continue_remaining()
  end, "nvime discuss active inline diff")
  set_keymap("n", prefix .. (normal.diff or "v"), function()
    require("nvime.diff").open_view()
  end, "nvime open diff review workspace")
  set_keymap("n", prefix .. (normal.last or "n"), M.open_last, "nvime reopen last conversation")
  set_keymap("n", prefix .. (normal.provider or "p"), provider.choose, "nvime choose provider")
  set_keymap("n", prefix .. (normal.plan or "P"), function()
    local plan = require("nvime.plan")
    -- If a plan UI float is already open but unfocused, refocus it instead of
    -- spawning a new picker on top. This is the answer to <C-w>w not reaching
    -- the float — `<leader>nP` always brings you back to the active surface.
    if plan.focus() then
      return
    end
    plan.picker()
  end, "nvime plans (or refocus)")

  set_keymap("x", prefix .. (visual.edit or "e"), visual_edit, "nvime edit visual selection")
  set_keymap("x", prefix .. (visual.ask or "q"), visual_ask, "nvime ask about visual selection")
end

local function parse_provider(args)
  local fargs = args.fargs or {}
  local provider_name = nil
  if fargs[1] == "claude" or fargs[1] == "codex" then
    provider_name = table.remove(fargs, 1)
  end
  return provider_name, table.concat(fargs, " ")
end

local function command_opts(args)
  local provider_name, rest = parse_provider(args)
  return {
    provider = provider_name,
    intent = rest,
    prompt = rest,
    line1 = args.line1,
    line2 = args.line2,
    range = args.range,
  }
end

function M.cancel()
  local count = 0
  local ok_chat, chat_cancelled = pcall(function()
    return require("nvime.chat").cancel_active()
  end)
  if ok_chat and chat_cancelled then
    count = count + 1
  end
  local ok_selection, selection_cancelled = pcall(function()
    return require("nvime.selection").cancel_active()
  end)
  if ok_selection and selection_cancelled then
    count = count + 1
  end
  if count == 0 then
    vim.notify("No running nvime agent to cancel", vim.log.levels.INFO)
  end
  return count
end

function M.disable()
  pcall(function()
    require("nvime.chat").cancel_all()
  end)
  pcall(function()
    require("nvime.selection").cancel_all()
  end)
  policy.restore()
  state.disabled = true
  pcall(function()
    require("nvime.audit").write({
      event = "nvime_disabled",
    })
  end)
  vim.notify("nvime disabled; run :NvimeEnable to re-enable it", vim.log.levels.WARN)
end

function M.enable()
  state.disabled = false
  if state.config and state.config.guard and state.config.guard.enabled then
    policy.install()
  end
  pcall(function()
    require("nvime.audit").write({
      event = "nvime_enabled",
    })
  end)
  vim.notify("nvime enabled", vim.log.levels.INFO)
end

function M.setup(opts)
  if vim.fn.has("nvim-0.10") == 0 then
    vim.notify("nvime requires Neovim 0.10+", vim.log.levels.ERROR)
    return
  end

  local user_opts = opts
  opts = opts or {}
  local force = opts.force == true
  if force then
    opts = vim.deepcopy(opts)
    opts.force = nil
  end

  local resolved = config.resolve(user_opts == nil and (state.config or {}) or opts)
  local setup_signature = vim.inspect(resolved)
  if state.setup_done and not force and state.setup_signature == setup_signature then
    return
  end

  if force or (state.guard_installed and resolved.guard and resolved.guard.enabled == false) then
    policy.restore()
  end

  state.config = resolved
  state.setup_signature = setup_signature

  if state.config.guard.enabled and not state.disabled then
    policy.install()
  end

  vim.api.nvim_create_user_command("NvimeReview", function(args)
    require("nvime.review").start(command_opts(args))
  end, {
    nargs = "*",
    desc = "Run an nvime review/docs lane through Claude or Codex",
  })

  vim.api.nvim_create_user_command("Nvime", function()
    require("nvime.chats").open({ mode = "dashboard" })
  end, {
    desc = "Open the nvime command center",
  })

  vim.api.nvim_create_user_command("NvimeEdit", function(args)
    require("nvime.edit").start(command_opts(args))
  end, {
    nargs = "*",
    range = true,
    desc = "Ask nvime for a focused current-file patch",
  })

  vim.api.nvim_create_user_command("NvimeAsk", function(args)
    local command = command_opts(args)
    command.question = command.prompt
    require("nvime.ask").start(command)
  end, {
    nargs = "*",
    range = true,
    desc = "Ask the read-only nvime side agent about a selection or current function",
  })

  vim.api.nvim_create_user_command("NvimeChat", function()
    require("nvime.chats").open({ mode = "chat" })
  end, {
    desc = "Open the nvime general chat conversation picker",
  })

  vim.api.nvim_create_user_command("NvimeChats", function(args)
    require("nvime.chats").open({
      mode = args.args ~= "" and args.args or nil,
    })
  end, {
    nargs = "?",
    complete = function()
      return { "dashboard", "chat", "ask", "edit" }
    end,
    desc = "Open the nvime chat or selection discussion picker",
  })

  vim.api.nvim_create_user_command("NvimeLast", M.open_last, {
    desc = "Reopen the last used nvime conversation",
  })

  vim.api.nvim_create_user_command("NvimeProvider", function(args)
    provider.set(args.args)
  end, {
    nargs = "?",
    complete = function()
      return provider.names
    end,
    desc = "Show or set the nvime provider",
  })

  vim.api.nvim_create_user_command("NvimeAudit", function(args)
    local fargs = args.fargs or {}
    local sub = fargs[1]
    if not sub or sub == "raw" then
      require("nvime.audit").open()
    elseif sub == "summary" then
      local days = tonumber(fargs[2]) or 7
      require("nvime.digest").show_summary(days)
    elseif sub == "forces" or sub == "force" or sub == "force-review" then
      require("nvime.digest").show_force_review()
    else
      vim.notify("nvime: usage `:NvimeAudit [raw|summary [days]|forces]`", vim.log.levels.WARN)
    end
  end, {
    nargs = "*",
    complete = function()
      return { "raw", "summary", "forces" }
    end,
    desc = "Open the nvime audit log (raw / summary / force-accept review)",
  })

  vim.api.nvim_create_user_command("NvimeCancel", M.cancel, {
    desc = "Cancel the active nvime agent run",
  })

  vim.api.nvim_create_user_command("NvimeDisable", M.disable, {
    desc = "Disable nvime wrappers and cancel running agents",
  })

  vim.api.nvim_create_user_command("NvimeEnable", M.enable, {
    desc = "Re-enable nvime wrappers after :NvimeDisable",
  })

  vim.api.nvim_create_user_command("NvimeAccept", function(args)
    require("nvime.diff").accept_current_group({
      force = args.bang,
    })
  end, {
    bang = true,
    desc = "Accept the current nvime inline diff block",
  })

  vim.api.nvim_create_user_command("NvimeReject", function()
    require("nvime.diff").reject_current_group()
  end, {
    desc = "Reject the current nvime inline diff block",
  })

  vim.api.nvim_create_user_command("NvimeDiff", function()
    require("nvime.diff").open_view()
  end, {
    desc = "Open the active nvime diff review workspace",
  })

  vim.api.nvim_create_user_command("NvimePlan", function(args)
    require("nvime.plan").command(args)
  end, {
    nargs = "*",
    complete = function(arg_lead, line)
      local items = require("nvime.plan").complete_subcommands(arg_lead, line)
      local out = {}
      for _, item in ipairs(items) do
        if arg_lead == "" or item:find(arg_lead, 1, true) == 1 then
          out[#out + 1] = item
        end
      end
      return out
    end,
    desc = "Open the nvime plan picker, draft a plan, or run a step",
  })

  vim.api.nvim_create_user_command("NvimeRecap", function(args)
    require("nvime.recap").command(args)
  end, {
    nargs = "*",
    complete = function()
      return { "claude", "codex", "--cached", "--staged" }
    end,
    desc = "Summarize the current git diff into a plan.md narrative under .nvime/plans/recap-<hash>/",
  })

  vim.api.nvim_create_user_command("NvimeAttribute", function(args)
    local attribution = require("nvime.attribution")
    local sub = (args.args or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if sub == "show" or sub == "on" then
      attribution.toggle_overlay(nil, "show")
    elseif sub == "hide" or sub == "off" or sub == "clear" then
      attribution.toggle_overlay(nil, "hide")
    elseif sub == "toggle" then
      attribution.toggle_overlay(nil)
    else
      attribution.show_at_cursor()
    end
  end, {
    nargs = "?",
    complete = function()
      return { "show", "hide", "toggle" }
    end,
    desc = "Show nvime attribution for the current line, or toggle the inline overlay",
  })

  vim.api.nvim_create_user_command("NvimePlanClose", function()
    require("nvime.plan").close_all()
  end, {
    desc = "Tear down every nvime plan UI float and backdrop (escape hatch)",
  })

  vim.api.nvim_create_user_command("NvimePlanFocus", function()
    if not require("nvime.plan").focus() then
      vim.notify("nvime: no open plan UI to focus", vim.log.levels.INFO)
    end
  end, {
    desc = "Refocus the active nvime plan UI float",
  })

  install_keymaps()

  pcall(vim.api.nvim_clear_autocmds, { group = persist_group })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = persist_group,
    callback = function()
      require("nvime.chat").flush_sessions()
      require("nvime.selection").flush_sessions()
    end,
  })

  pcall(vim.api.nvim_clear_autocmds, { group = audit_group })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = audit_group,
    callback = function()
      require("nvime.audit").clear_cache()
    end,
  })

  state.setup_done = true
end

function M.edit(opts)
  return require("nvime.edit").start(opts)
end

function M.review(opts)
  return require("nvime.review").start(opts)
end

return M
