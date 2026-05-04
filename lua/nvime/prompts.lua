local state = require("nvime.state")

local M = {}

local function configured(scope)
  local prompts = (state.config or {}).prompts or {}
  local items = prompts[scope] or prompts.general or {}
  if type(items) ~= "table" then
    return {}
  end
  return items
end

local function prompt_text(item)
  if type(item) == "string" then
    return item
  end
  if type(item) ~= "table" then
    return nil
  end
  return item.prompt or item.text or item.value
end

local function prompt_label(item)
  if type(item) == "string" then
    return item
  end
  if type(item) ~= "table" then
    return tostring(item)
  end
  return item.label or item.name or prompt_text(item) or "(empty prompt)"
end

function M.choose(scope, callback)
  local items = configured(scope)
  if #items == 0 then
    vim.notify("No nvime prompt templates configured", vim.log.levels.INFO)
    return
  end
  vim.ui.select(items, {
    prompt = "nvime prompt",
    format_item = prompt_label,
  }, function(choice)
    local text = prompt_text(choice)
    if text and text ~= "" then
      callback(text)
    end
  end)
end

return M
