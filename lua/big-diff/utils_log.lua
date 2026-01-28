local M = {}

M.error = function(msg)
  error('(big-diff) ' .. msg, 0)
end

M.notify = function(msg, level_name)
  vim.notify('(big-diff) ' .. msg, vim.log.levels[level_name])
end

return M
