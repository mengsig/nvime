local state = require("nvime.state")

local M = {}

M.names = { "claude", "codex" }

local function normalize_opts(opts)
  if type(opts) == "string" then
    return { scope = opts }
  end
  return opts or {}
end

local function active_selection_session()
  local selection = state.selection or {}
  local active_id = selection.active_session_id
  if not active_id or type(selection.sessions) ~= "table" then
    return nil
  end
  for _, session in ipairs(selection.sessions) do
    if session.id == active_id then
      return session
    end
  end
  return nil
end

local function current_selection_provider()
  local session = active_selection_session()
  if session and session.provider then
    return session.provider
  end
  return state.selection and state.selection.provider
end

local function active_chat_session()
  local chat = state.chat or {}
  local active_id = chat.active_session_id
  if not active_id or type(chat.sessions) ~= "table" then
    return nil
  end
  for _, session in ipairs(chat.sessions) do
    if session.id == active_id then
      return session
    end
  end
  return nil
end

local function current_chat_provider()
  local session = active_chat_session()
  if session and session.provider then
    return session.provider
  end
  return state.chat and state.chat.provider
end

local function set_active_selection_provider(name)
  state.selection = state.selection or {}
  state.selection.provider = name
  local session = active_selection_session()
  if session then
    session.provider = name
    if session.pending_input then
      session.pending_input.provider = name
      state.selection.pending_input = session.pending_input
    end
  end
end

local function set_active_chat_provider(name)
  state.chat = state.chat or {}
  state.chat.provider = name
  local session = active_chat_session()
  if session then
    session.provider = name
  end
end

function M.current(opts)
  opts = normalize_opts(opts)
  if opts.scope == "selection" then
    return current_selection_provider() or (state.config and state.config.provider) or "claude"
  end
  if opts.scope == "chat" then
    return current_chat_provider() or (state.config and state.config.provider) or "claude"
  end
  return (state.config and state.config.provider) or "claude"
end

function M.set(name, opts)
  opts = normalize_opts(opts)
  if not name or name == "" then
    if not opts.silent then
      vim.notify("nvime provider: " .. tostring(M.current(opts)), vim.log.levels.INFO)
    end
    return M.current(opts)
  end
  if not state.config.providers[name] then
    vim.notify("Unknown nvime provider: " .. tostring(name), vim.log.levels.ERROR)
    return M.current(opts)
  end
  state.config.provider = name

  local update_selection = opts.scope == "selection" or (not opts.scope and state.panels and state.panels.selection)
  local update_chat = opts.scope == "chat" or (not opts.scope and state.panels and state.panels.chat)
  if update_selection then
    set_active_selection_provider(name)
  end
  if update_chat then
    set_active_chat_provider(name)
  end
  if opts.scope ~= "selection" then
    pcall(function()
      require("nvime.chat").refresh()
    end)
  end
  if update_selection then
    pcall(function()
      require("nvime.selection").refresh()
    end)
  end
  if not opts.silent then
    vim.notify("nvime provider set to " .. name, vim.log.levels.INFO)
  end
  return name
end

function M.cycle(opts)
  opts = normalize_opts(opts)
  local current = M.current(opts)
  for index, name in ipairs(M.names) do
    if name == current then
      return M.set(M.names[(index % #M.names) + 1], opts)
    end
  end
  return M.set(M.names[1], opts)
end

function M.choose(opts)
  opts = normalize_opts(opts)
  vim.ui.select(M.names, {
    prompt = "nvime provider",
    format_item = function(item)
      if item == M.current(opts) then
        return item .. " (current)"
      end
      return item
    end,
  }, function(choice)
    if choice then
      M.set(choice, opts)
    end
  end)
end

-- Model management --------------------------------------------------------

local function provider_models(provider_name)
  provider_name = provider_name or M.current()
  local cfg = state.config and state.config.providers and state.config.providers[provider_name]
  return (cfg and cfg.models) or {}
end

local function current_selection_model()
  local session = active_selection_session()
  return session and session.model
end

local function current_chat_model()
  local session = active_chat_session()
  return session and session.model
end

local function set_active_selection_model(model)
  state.selection = state.selection or {}
  state.selection.model = model
  local session = active_selection_session()
  if session then
    session.model = model
  end
end

local function set_active_chat_model(model)
  state.chat = state.chat or {}
  state.chat.model = model
  local session = active_chat_session()
  if session then
    session.model = model
  end
end

function M.current_model(opts)
  opts = normalize_opts(opts)
  if opts.scope == "selection" then
    return current_selection_model() or (state.selection and state.selection.model)
  end
  if opts.scope == "chat" then
    return current_chat_model() or (state.chat and state.chat.model)
  end
  return nil
end

function M.set_model(model, opts)
  opts = normalize_opts(opts)
  local update_selection = opts.scope == "selection" or (not opts.scope and state.panels and state.panels.selection)
  local update_chat = opts.scope == "chat" or (not opts.scope and state.panels and state.panels.chat)
  if update_selection then
    set_active_selection_model(model)
  end
  if update_chat then
    set_active_chat_model(model)
  end
  if opts.scope ~= "selection" then
    pcall(function()
      require("nvime.chat").refresh()
    end)
  end
  if update_selection then
    pcall(function()
      require("nvime.selection").refresh()
    end)
  end
  vim.notify("nvime model set to " .. (model or "(provider default)"), vim.log.levels.INFO)
  return model
end

function M.cycle_model(opts)
  opts = normalize_opts(opts)
  local models = provider_models(M.current(opts))
  if #models == 0 then
    vim.notify("No model options for " .. M.current(opts), vim.log.levels.WARN)
    return nil
  end
  local current = M.current_model(opts)
  if not current then
    return M.set_model(models[1], opts)
  end
  for index, name in ipairs(models) do
    if name == current then
      return M.set_model(models[(index % #models) + 1], opts)
    end
  end
  return M.set_model(models[1], opts)
end

function M.choose_model(opts)
  opts = normalize_opts(opts)
  local provider_name = M.current(opts)
  local models = provider_models(provider_name)
  if #models == 0 then
    vim.notify("No model options for " .. provider_name, vim.log.levels.WARN)
    return
  end
  local current = M.current_model(opts)
  local choices = {}
  for _, m in ipairs(models) do
    choices[#choices + 1] = m
  end
  table.insert(choices, 1, "(provider default)")
  vim.ui.select(choices, {
    prompt = "nvime model (" .. provider_name .. ")",
    format_item = function(item)
      if item == current then
        return item .. " (current)"
      end
      if item == "(provider default)" and not current then
        return item .. " (current)"
      end
      return item
    end,
  }, function(choice)
    if choice then
      if choice == "(provider default)" then
        M.set_model(nil, opts)
      else
        M.set_model(choice, opts)
      end
    end
  end)
end

return M
