local M = {}

function M.compact(text)
  text = vim.trim(text or "")
  if text == "" then
    return ""
  end

  text = text:gsub("%s+", " ")
  text = text:gsub("^%[nvime%]%s*", "")

  local provider, tool = text:match("^%[([^%]]+)%]%s+tool:%s*([^:]+)")
  if provider and tool then
    tool = vim.trim(tool)
    if tool:find("%s") or tool:find("/") then
      tool = "tool"
    end
    text = provider .. " " .. vim.trim(tool)
  else
    local bracketed, rest = text:match("^%[([^%]]+)%]%s*(.+)$")
    if bracketed and rest then
      text = bracketed .. " " .. vim.trim(rest)
    end
  end

  if #text > 64 then
    text = text:sub(1, 61) .. "..."
  end
  return text
end

return M
