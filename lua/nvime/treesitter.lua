local M = {}

local function function_type(node_type)
  if not node_type then
    return false
  end
  if node_type == "call_expression" or node_type == "call" then
    return false
  end
  if node_type:find("function", 1, true) then
    return true
  end
  return vim.tbl_contains({
    "method_definition",
    "method_declaration",
    "function_item",
    "function_statement",
    "function_declaration",
    "function_definition",
    "arrow_function",
    "lambda_expression",
    "constructor_declaration",
  }, node_type)
end

function M.current_function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local ok = pcall(function()
    vim.treesitter.get_parser(bufnr):parse()
  end)
  if not ok then
    return nil, "Tree-sitter parser is not available for this buffer"
  end

  local node = vim.treesitter.get_node({
    bufnr = bufnr,
    pos = { row, col },
    ignore_injections = false,
  })

  while node do
    if function_type(node:type()) then
      local start_row, start_col, end_row, end_col = node:range()
      return {
        bufnr = bufnr,
        line1 = start_row + 1,
        col1 = start_col,
        line2 = end_row + 1,
        col2 = end_col,
        source = "treesitter",
        node_type = node:type(),
      }
    end
    node = node:parent()
  end

  return nil, "No function node found at cursor"
end

function M.range_from_command(opts)
  if opts and opts.range and opts.range > 0 then
    return {
      bufnr = vim.api.nvim_get_current_buf(),
      line1 = opts.line1,
      line2 = opts.line2,
      col1 = 0,
      col2 = 0,
      source = "range",
    }
  end
  return M.current_function(vim.api.nvim_get_current_buf())
end

function M.lines(range)
  return vim.api.nvim_buf_get_lines(range.bufnr, range.line1 - 1, range.line2, false)
end

return M
