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

function M.current(opts)
  opts = normalize_opts(opts)
  if opts.scope == "selection" then
    return current_selection_provider() or (state.config and state.config.provider) or "claude"
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
  if update_selection then
    set_active_selection_provider(name)
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

return M
