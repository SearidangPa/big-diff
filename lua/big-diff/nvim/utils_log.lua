local M = {}

M.error = function(msg)
  error('(big-diff.nvim) ' .. msg, 0)
end

M.notify = function(msg, level_name)
  vim.notify('(big-diff.nvim) ' .. msg, vim.log.levels[level_name])
end

return M
