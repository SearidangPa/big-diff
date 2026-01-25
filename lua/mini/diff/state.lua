local M = {}

-- Timers
M.timer_diff_update = vim.loop.new_timer()

-- Namespaces per highlighter name
M.ns_id = {
  viz = vim.api.nvim_create_namespace('MiniDiffViz'),
  overlay = vim.api.nvim_create_namespace('MiniDiffOverlay'),
}

-- Cache of buffers waiting for debounced diff update
M.bufs_to_update = {}

-- Cache per enabled buffer
M.cache = {}

-- Cache per buffer for attached `git` source
M.git_cache = {}

-- Cache for operator
M.operator_cache = {}

-- Global overlay state
M.overlay = false

-- Treesitter syntax highlighting for overlay
M.ts_cache = {}
M.blended_hl_cache = {}

-- Permanent `vim.diff()` options
M.vimdiff_opts = { result_type = 'indices', ctxlen = 0, interhunkctxlen = 0 }

-- Options for `vim.diff()` during word diff. Use `interhunkctxlen = 4` to
-- reduce noisiness (chosen as slightly less than average English word length)
--stylua: ignore
M.worddiff_opts = {
  algorithm = 'minimal',
  result_type = 'indices',
  ctxlen = 0,
  interhunkctxlen = 4,
  indent_heuristic = false,
  linematch = 0
}

return M
