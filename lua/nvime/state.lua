local M = {
  config = nil,
  setup_done = false,
  guard_installed = false,
  trusted_depth = 0,
  panels = {},
  current_diff = nil,
  running = {},
  raw = {},
  keymaps = {},
  chat = {
    active_session_id = nil,
    next_session_id = 1,
    sessions = {},
    history = {},
    provider_sessions = {},
    provider_workspaces = {},
    last_provider = nil,
  },
  selection = {
    last_ask = nil,
    last_edit_prompt = nil,
    active_session_id = nil,
    next_session_id = 1,
    sessions = {},
  },
}

return M
