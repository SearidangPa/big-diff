local H = require('mini.diff.utils_val')
local M = {}

M.default_config = {
  -- Options for how hunks are visualized
  view = {
    -- Visualization style. Possible values are 'sign' and 'number'.
    -- Default: 'number' if line numbers are enabled, 'sign' otherwise.
    style = vim.go.number and 'number' or 'sign',

    -- Signs used for hunks with 'sign' view
    signs = { add = '▒', change = '▒', delete = '▒' },

    -- Priority of used visualization extmarks
    priority = 199,

    -- Float window settings for hunk navigation display
    float = {
      -- Width of the floating window
      width = 9,

      -- Window blend (transparency, 0-100)
      winblend = 50,

      -- Z-index of the floating window
      zindex = 1,

      -- Throttle delay (ms) for CursorMoved updates
      throttle_ms = 100,
    },
  },

  -- Source(s) for how reference text is computed/updated/etc
  -- Uses content from Git index by default
  source = nil,

  -- Delays (in ms) defining asynchronous processes
  delay = {
    -- How much to wait before update following every text change
    text_change = 200,
  },

  -- Module mappings. Use '' (empty string) to disable one.
  mappings = {
    -- Apply hunks inside a visual/operator region
    apply = 'gh',

    -- Reset hunks inside a visual/operator region
    reset = 'gH',

    -- Hunk range textobject to be used inside operator
    -- Works also in Visual mode if mapping differs from apply and reset
    textobject = 'gh',

    -- Go to hunk range in corresponding direction
    goto_first = '[H',
    goto_prev = '[h',
    goto_next = ']h',
    goto_last = ']H',

    -- Toggle floating window display for hunk navigation
    toggle_float = '<leader>th',
  },

  -- Various options
  options = {
    -- Diff algorithm. See `:h vim.text.diff()`
    algorithm = 'histogram',

    -- Whether to use "indent heuristic". See `:h vim.text.diff()`
    indent_heuristic = true,

    -- The amount of second-stage diff to align lines
    linematch = 60,

    -- Whether to ignore all whitespace differences
    ignore_whitespace = false,

    -- Whether to wrap around edges during hunk navigation
    wrap_goto = false,
  },
}

M.setup_config = function(config)
  H.check_type('config', config, 'table', true)
  config = vim.tbl_deep_extend('force', vim.deepcopy(M.default_config), config or {})

  H.check_type('view', config.view, 'table')
  H.check_type('view.style', config.view.style, 'string')
  H.check_type('view.signs', config.view.signs, 'table')
  H.check_type('view.signs.add', config.view.signs.add, 'string')
  H.check_type('view.signs.change', config.view.signs.change, 'string')
  H.check_type('view.signs.delete', config.view.signs.delete, 'string')
  H.check_type('view.priority', config.view.priority, 'number')
  H.check_type('view.float', config.view.float, 'table')
  H.check_type('view.float.width', config.view.float.width, 'number')
  H.check_type('view.float.winblend', config.view.float.winblend, 'number')
  H.check_type('view.float.zindex', config.view.float.zindex, 'number')
  H.check_type('view.float.throttle_ms', config.view.float.throttle_ms, 'number')

  H.check_type('source', config.source, 'table', true)

  H.check_type('delay', config.delay, 'table')
  H.check_type('delay.text_change', config.delay.text_change, 'number')

  H.check_type('mappings', config.mappings, 'table')
  H.check_type('mappings.apply', config.mappings.apply, 'string')
  H.check_type('mappings.reset', config.mappings.reset, 'string')
  H.check_type('mappings.textobject', config.mappings.textobject, 'string')
  H.check_type('mappings.goto_first', config.mappings.goto_first, 'string')
  H.check_type('mappings.goto_prev', config.mappings.goto_prev, 'string')
  H.check_type('mappings.goto_next', config.mappings.goto_next, 'string')
  H.check_type('mappings.goto_last', config.mappings.goto_last, 'string')
  H.check_type('mappings.toggle_float', config.mappings.toggle_float, 'string')

  H.check_type('options', config.options, 'table')
  H.check_type('options.algorithm', config.options.algorithm, 'string')
  H.check_type('options.indent_heuristic', config.options.indent_heuristic, 'boolean')
  H.check_type('options.linematch', config.options.linematch, 'number')
  H.check_type('options.wrap_goto', config.options.wrap_goto, 'boolean')

  return config
end

M.get_buf_var = function(buf_id, name)
  if not vim.api.nvim_buf_is_valid(buf_id) then return nil end
  return vim.b[buf_id or 0][name]
end

-- Use `MiniDiff.config` as a global config, but allow local override
M.get_config = function(config, buf_id)
  local buf_config = M.get_buf_var(buf_id, 'minidiff_config') or {}
  return vim.tbl_deep_extend('force', _G.MiniDiff.config, buf_config, config or {})
end

M.is_disabled = function(buf_id)
  local buf_disable = M.get_buf_var(buf_id, 'minidiff_disable')
  return vim.g.minidiff_disable == true or buf_disable == true
end

M.normalize_source = function(source)
  -- Normalize to an array of sources
  if type(source) ~= 'table' then H.error('`source` should be table.') end
  if source[1] == nil then source = { source } end

  local res = {}
  for i, s in ipairs(source) do
    local cur_s = { attach = s.attach }
    cur_s.name = s.name or 'unknown'
    cur_s.detach = s.detach or function(_) end
    cur_s.apply_hunks = s.apply_hunks or function(_) H.error('Current source does not support applying hunks.') end

    if type(cur_s.name) ~= 'string' then H.error('`source.name` should be string.') end
    H.validate_callable(cur_s.attach, 'source.attach')
    H.validate_callable(cur_s.detach, 'source.detach')
    H.validate_callable(cur_s.apply_hunks, 'source.apply_hunks')

    res[i] = cur_s
  end

  return res
end

return M
