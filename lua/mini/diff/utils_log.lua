local M = {}

M.error = function(msg)
  error('(mini.diff) ' .. msg, 0)
end

M.notify = function(msg, level_name)
  vim.notify('(mini.diff) ' .. msg, vim.log.levels[level_name])
end

return M
