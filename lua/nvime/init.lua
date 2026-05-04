local config = require("nvime.config")
local policy = require("nvime.policy")
local provider = require("nvime.provider")
local state = require("nvime.state")

local M = {}

local persist_group = vim.api.nvim_create_augroup("nvime.persist", { clear = false })

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
  if running > 0 then
    return string.format("nvime %d/%d running", running, total)
  end
  return string.format("nvime %d", total)
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

  set_keymap("n", prefix .. (normal.chat or "c"), "<Cmd>NvimeChat<CR>", "nvime chat conversations")
  set_keymap("n", prefix .. (normal.review or "r"), "<Cmd>NvimeReview<CR>", "nvime review/docs")
  set_keymap("n", prefix .. (normal.edit or "e"), "<Cmd>NvimeChats edit<CR>", "nvime edit discussions")
  set_keymap("n", prefix .. (normal.ask or "q"), "<Cmd>NvimeChats ask<CR>", "nvime ask discussions")
  set_keymap("n", prefix .. (normal.audit or "a"), "<Cmd>NvimeAudit<CR>", "nvime audit log")
  set_keymap("n", prefix .. (normal.discuss or "d"), function()
    require("nvime.edit").continue_remaining()
  end, "nvime discuss active inline diff")
  set_keymap("n", prefix .. (normal.last or "n"), M.open_last, "nvime reopen last conversation")
  set_keymap("n", prefix .. (normal.provider or "p"), provider.choose, "nvime choose provider")

  set_keymap("x", prefix .. (visual.edit or "e"), visual_edit, "nvime edit visual selection")
  set_keymap("x", prefix .. (visual.ask or "q"), visual_ask, "nvime ask about visual selection")
end

local function parse_provider(args)
  local fargs = args.fargs or {}
  local provider = nil
  if fargs[1] == "claude" or fargs[1] == "codex" then
    provider = table.remove(fargs, 1)
  end
  return provider, table.concat(fargs, " ")
end

local function command_opts(args)
  local provider, rest = parse_provider(args)
  return {
    provider = provider,
    intent = rest,
    prompt = rest,
    line1 = args.line1,
    line2 = args.line2,
    range = args.range,
  }
end

function M.setup(opts)
  state.config = config.resolve(opts or state.config or {})

  if state.config.guard.enabled then
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
    local opts = command_opts(args)
    opts.question = opts.prompt
    require("nvime.ask").start(opts)
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

  vim.api.nvim_create_user_command("NvimeAudit", function()
    require("nvime.audit").open()
  end, {
    desc = "Open the nvime audit log",
  })

  vim.api.nvim_create_user_command("NvimeAccept", function()
    require("nvime.diff").accept_current_group()
  end, {
    desc = "Accept the current nvime inline diff block",
  })

  vim.api.nvim_create_user_command("NvimeReject", function()
    require("nvime.diff").reject_current_group()
  end, {
    desc = "Reject the current nvime inline diff block",
  })

  install_keymaps()

  pcall(vim.api.nvim_clear_autocmds, { group = persist_group })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = persist_group,
    callback = function()
      require("nvime.chat").save_sessions()
      require("nvime.selection").save_sessions()
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
