local M = {}

M.defaults = {
  provider = "claude",
  providers = {
    claude = {
      cmd = "claude",
    },
    codex = {
      cmd = "codex",
    },
  },
  ui = {
    layout = "float",
    side = "right",
    width = 82,
    height = 24,
    float_width = 0.82,
    float_height = 0.72,
    dashboard_width = 0.86,
    dashboard_height = 0.9,
    border = "rounded",
    backdrop = 60,
    completion = "notify",
    ascii_icons = false,
    icons = {},
    spinner_frames = nil,
  },
  audit = {
    enabled = true,
    path = nil,
    log_prompts = false,
  },
  guard = {
    enabled = true,
    strict = true,
    notify = true,
    wrap_vim_system = true,
    wrap_jobstart = true,
    wrap_termopen = true,
    wrap_system_functions = true,
    wrap_uv_spawn = true,
    kill_blocked_terminals = true,
    block_cmdline = true,
  },
  review = {
    allow_shell = true,
    allow_web = true,
    allow_markdown_writes = true,
  },
  selection = {
    allow_shell = true,
    allow_web = true,
  },
  edit = {
    context_lines = 0,
  },
  diff = {
    max_visual_block_lines = 12,
  },
  chat = {
    max_history_messages = 24,
  },
  sessions = {
    enabled = true,
    path = nil,
    chat_path = nil,
    max = 100,
  },
  keys = {
    enabled = true,
    prefix = "<leader>n",
    normal = {
      dashboard = "<Space>",
      chat = "c",
      review = "r",
      edit = "e",
      ask = "q",
      audit = "a",
      discuss = "d",
      diff = "v",
      last = "n",
      provider = "p",
    },
    visual = {
      edit = "e",
      ask = "q",
    },
  },
  prompts = {
    general = {
      {
        label = "Review repository",
        prompt = "Please review this repository for correctness, maintainability, and documentation drift. Run relevant read-only checks and summarize concrete findings.",
      },
      {
        label = "Update docs",
        prompt = "Please inspect the repository and ensure the Markdown documentation is accurate, complete, and easy for future agents to use.",
      },
      {
        label = "Explain architecture",
        prompt = "Please explain the repository architecture, important modules, data flow, and the safest places to make changes.",
      },
      {
        label = "Run tests",
        prompt = "Please run the relevant tests/checks, explain failures if any, and recommend the smallest next fix.",
      },
    },
    selection = {
      {
        label = "Review selection",
        prompt = "Please review this selection for correctness, maintainability, edge cases, and whether it fits the surrounding code.",
      },
      {
        label = "Explain selection",
        prompt = "Please explain what this selected code does and how it interacts with the rest of the repository.",
      },
      {
        label = "Suggest minimal diff",
        prompt = "Please suggest the smallest approvable diff for this selection, and avoid changing unrelated lines.",
      },
      {
        label = "Proceed with fix",
        prompt = "Please proceed with the concrete fix for this selection, keeping the change minimal and inside the selected range.",
      },
      {
        label = "Benchmark and optimize",
        prompt = "Profile this selection on representative inputs, propose a faster candidate, verify behavior parity, and only patch if there is a measurable speedup. Include a one-line BENCH summary above the response block.",
        lane = "perf",
      },
    },
  },
}

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local optional_types = {
  ["audit.path"] = { "string", "nil" },
  ["sessions.path"] = { "string", "nil" },
  ["sessions.chat_path"] = { "string", "nil" },
  ["ui.spinner_frames"] = { "table", "nil" },
}

local function type_label(value)
  if type(value) == "table" and is_list(value) then
    return "list"
  end
  return type(value)
end

local function matches_type(value, expected)
  if type(expected) == "table" then
    for _, item in ipairs(expected) do
      if matches_type(value, item) then
        return true
      end
    end
    return false
  end
  if expected == "list" then
    return is_list(value)
  end
  if expected == "integer" then
    return type(value) == "number" and value % 1 == 0
  end
  return type(value) == expected
end

local function validate_with_vim(path, value, expected)
  local validator = expected
  if expected == "integer" then
    validator = function(item)
      return matches_type(item, "integer")
    end
  elseif expected == "list" then
    validator = function(item)
      return is_list(item)
    end
  elseif type(expected) == "table" then
    validator = function(item)
      return matches_type(item, expected)
    end
  end
  if pcall(vim.validate, { [path] = { value, validator } }) then
    return true
  end
  if pcall(vim.validate, path, value, validator) then
    return true
  end
  return false
end

local function warn(warnings, message)
  warnings[#warnings + 1] = message
end

local function validate_leaf(warnings, path, value, expected)
  if not validate_with_vim(path, value, expected) or not matches_type(value, expected) then
    local label = type(expected) == "table" and table.concat(expected, "|") or expected
    warn(warnings, path .. " should be " .. label .. ", got " .. type_label(value))
  end
end

local function validate_provider(warnings, name, value)
  local path = "providers." .. tostring(name)
  if type(value) ~= "table" then
    validate_leaf(warnings, path, value, "table")
    return
  end
  for key, item in pairs(value) do
    local child = path .. "." .. tostring(key)
    if key == "cmd" then
      validate_leaf(warnings, child, item, "string")
    else
      warn(warnings, "unknown nvime config key: " .. child)
    end
  end
end

local function validate_prompt_entry(warnings, path, value)
  if type(value) ~= "table" then
    validate_leaf(warnings, path, value, "table")
    return
  end
  for key, item in pairs(value) do
    local child = path .. "." .. tostring(key)
    if key == "label" or key == "prompt" or key == "lane" then
      validate_leaf(warnings, child, item, "string")
    else
      warn(warnings, "unknown nvime config key: " .. child)
    end
  end
end

local function validate_prompts(warnings, path, value)
  if type(value) ~= "table" then
    validate_leaf(warnings, path, value, "table")
    return
  end
  for name, items in pairs(value) do
    local child = path .. "." .. tostring(name)
    if not is_list(items) then
      validate_leaf(warnings, child, items, "list")
    else
      for index, item in ipairs(items) do
        validate_prompt_entry(warnings, child .. "." .. tostring(index), item)
      end
    end
  end
end

local function validate_icons(warnings, path, value)
  if type(value) ~= "table" then
    validate_leaf(warnings, path, value, "table")
    return
  end
  for name, item in pairs(value) do
    validate_leaf(warnings, path .. "." .. tostring(name), item, "string")
  end
end

local function validate_table(warnings, user, schema, path)
  if type(user) ~= "table" then
    validate_leaf(warnings, path ~= "" and path or "opts", user, "table")
    return
  end
  for key, value in pairs(user) do
    if not (path == "" and key == "force") then
      local child = path ~= "" and (path .. "." .. tostring(key)) or tostring(key)
      if child == "providers" then
        if type(value) ~= "table" then
          validate_leaf(warnings, child, value, "table")
        else
          for provider_name, provider_opts in pairs(value) do
            validate_provider(warnings, provider_name, provider_opts)
          end
        end
      elseif child == "prompts" then
        validate_prompts(warnings, child, value)
      elseif child == "ui.icons" then
        validate_icons(warnings, child, value)
      elseif optional_types[child] then
        validate_leaf(warnings, child, value, optional_types[child])
      elseif schema[key] == nil then
        warn(warnings, "unknown nvime config key: " .. child)
      elseif type(schema[key]) == "table" and not is_list(schema[key]) then
        validate_table(warnings, value, schema[key], child)
      else
        validate_leaf(warnings, child, value, type_label(schema[key]))
      end
    end
  end
end

function M.validate(opts)
  local warnings = {}
  validate_table(warnings, opts or {}, M.defaults, "")
  for _, message in ipairs(warnings) do
    vim.notify(message, vim.log.levels.WARN)
  end
  return warnings
end

local function merge(base, override)
  local out = vim.deepcopy(base)
  for key, value in pairs(override or {}) do
    if type(value) == "table" and type(out[key]) == "table" and not is_list(value) then
      out[key] = merge(out[key], value)
    else
      out[key] = value
    end
  end
  return out
end

function M.resolve(opts)
  M.validate(opts or {})
  return merge(M.defaults, opts or {})
end

return M
