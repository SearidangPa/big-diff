local H = require('mini.diff.utils_log')
local M = {}

M.validate_buf_id = function(x)
  if x == nil or x == 0 then return vim.api.nvim_get_current_buf() end
  if not (type(x) == 'number' and vim.api.nvim_buf_is_valid(x)) then
    H.error('`buf_id` should be `nil` or valid buffer id.')
  end
  return x
end

M.validate_target_lines = function(buf_id, line_start, line_end)
  local n_lines = vim.api.nvim_buf_line_count(buf_id)

  if type(line_start) ~= 'number' then H.error('`line_start` should be number.') end
  if type(line_end) ~= 'number' then H.error('`line_end` should be number.') end

  -- Allow negative lines to count from last line
  line_start = line_start < 0 and (n_lines + line_start + 1) or line_start
  line_end = line_end < 0 and (n_lines + line_end + 1) or line_end

  -- Clamp to fit the allowed range
  line_start = math.min(math.max(line_start, 1), n_lines)
  line_end = math.min(math.max(line_end, 1), n_lines)
  if not (line_start <= line_end) then H.error('`line_start` should be less than or equal to `line_end`.') end

  return line_start, line_end
end

M.validate_callable = function(x, name)
  if vim.is_callable(x) then return x end
  H.error('`' .. name .. '` should be callable.')
end

M.check_type = function(name, val, ref, allow_nil)
  if type(val) == ref or (ref == 'callable' and vim.is_callable(val)) or (allow_nil and val == nil) then return end
  H.error(string.format('`%s` should be %s, not %s', name, ref, type(val)))
end

return M
