local H = {
  log = require('mini.diff.utils_log'),
  val = require('mini.diff.utils_val'),
  vim = require('mini.diff.utils_vim'),
  state = require('mini.diff.state'),
  config = require('mini.diff.config'),
}

local M = {}

-- Helpers --------------------------------------------------------------------
local get_active_source = function(buf_cache) return buf_cache.source[buf_cache.source_id] or {} end

local hunk_order = function(a, b)
  -- Ensure buffer order and that "change" hunks are listed earlier "delete"
  -- ones from the same line (important for `reset_hunks()`)
  return a.buf_start < b.buf_start or (a.buf_start == b.buf_start and a.type == 'change')
end

local get_hunk_buf_range = function(hunk)
  -- "Change" and "Add" hunks have the range `[from, from + buf_count - 1]`
  if hunk.buf_count > 0 then return hunk.buf_start, hunk.buf_start + hunk.buf_count - 1 end
  -- "Delete" hunks have `buf_count = 0` yet its range is `[from, from]`
  -- `buf_start` can be 0 for 'delete' hunk, yet range should be real lines
  local from = math.max(hunk.buf_start, 1)
  return from, from
end

local get_hunks_in_range = function(hunks, from, to)
  local res = {}
  for _, h in ipairs(hunks) do
    local h_from, h_to = get_hunk_buf_range(h)

    local left, right = math.max(from, h_from), math.min(to, h_to)
    if left <= right then
      -- If any `cur` hunk part is selected, its `ref` part is used fully
      local new_h = { ref_start = h.ref_start, ref_count = h.ref_count }
      new_h.type = h.ref_count == 0 and 'add' or (h.buf_count == 0 and 'delete' or 'change')

      -- It should be possible to work with only hunk part inside target range
      -- Also Treat "delete" hunks differently as they represent range differently
      -- and can have `buf_start=0`
      new_h.buf_start = new_h.type == 'delete' and h.buf_start or left
      new_h.buf_count = new_h.type == 'delete' and 0 or (right - left + 1)

      table.insert(res, new_h)
    end
  end

  table.sort(res, hunk_order)
  return res
end

local reset_hunks = function(buf_id, hunks)
  local ref_lines = vim.split(H.state.cache[buf_id].ref_text, '\n')
  local offset = 0
  for _, h in ipairs(hunks) do
    -- Replace current hunk lines with corresponding reference
    local new_lines = vim.list_slice(ref_lines, h.ref_start, h.ref_start + h.ref_count - 1)

    -- Compute buffer offset from parts: result of previous replaces, "delete"
    -- hunk offset which starts below the `buf_start` line, zero-indexing.
    local buf_offset = offset + (h.buf_count == 0 and 1 or 0) - 1
    local from, to = h.buf_start + buf_offset, h.buf_start + h.buf_count + buf_offset
    vim.api.nvim_buf_set_lines(buf_id, from, to, false, new_lines)

    -- Keep track of current hunk lines shift as a result of previous replaces
    offset = offset + (h.ref_count - h.buf_count)
  end
end

local yank_hunks_ref = function(ref_text, hunks, register)
  -- Collect reference lines
  local ref_lines, out_lines = vim.split(ref_text, '\n'), {}
  for _, h in ipairs(hunks) do
    for i = h.ref_start, h.ref_start + h.ref_count - 1 do
      out_lines[i] = ref_lines[i]
    end
  end

  -- Construct reference lines in order
  local hunk_ref_lines = {}
  for i = 1, #ref_lines do
    table.insert(hunk_ref_lines, out_lines[i])
  end

  -- Put lines into target register
  vim.fn.setreg(register, hunk_ref_lines, 'l')
end

local get_contiguous_hunk_ranges = function(hunks)
  if #hunks == 0 then return {} end
  hunks = vim.deepcopy(hunks)
  table.sort(hunks, hunk_order)

  local h1_from, h1_to = get_hunk_buf_range(hunks[1])
  local res = { { from = h1_from, to = h1_to } }
  for i = 2, #hunks do
    local h, cur_region = hunks[i], res[#res]
    local h_from, h_to = get_hunk_buf_range(h)
    if h_from <= cur_region.to + 1 then
      cur_region.to = math.max(cur_region.to, h_to)
    else
      table.insert(res, { from = h_from, to = h_to })
    end
  end
  return res
end

local get_range_id_next = function(ranges, line_start)
  for i = #ranges, 1, -1 do
    if ranges[i].from <= line_start then return i end
  end
  return 0
end

local get_range_id_prev = function(ranges, line_start)
  for i = 1, #ranges do
    if line_start <= ranges[i].to then return i end
  end
  return #ranges + 1
end

local iterate_hunk_ranges = function(ranges, direction, opts)
  local n = #ranges

  -- Compute initial index
  local init_ind
  if direction == 'first' then init_ind = 0 end
  if direction == 'prev' then init_ind = get_range_id_prev(ranges, opts.line_start) end
  if direction == 'next' then init_ind = get_range_id_next(ranges, opts.line_start) end
  if direction == 'last' then init_ind = n + 1 end

  local is_on_edge = (direction == 'prev' and init_ind == 1) or (direction == 'next' and init_ind == n)
  if not opts.wrap and is_on_edge then return nil end

  -- Compute destination index
  local is_move_forward = direction == 'first' or direction == 'next'
  local res_ind = init_ind + opts.n_times * (is_move_forward and 1 or -1)
  local did_wrap = opts.wrap and (res_ind < 1 or n < res_ind)
  res_ind = opts.wrap and ((res_ind - 1) % n + 1) or math.min(math.max(res_ind, 1), n)

  return res_ind, did_wrap
end

local export_qf = function(opts)
  local buffers = opts.scope == 'current' and { vim.api.nvim_get_current_buf() } or vim.tbl_keys(H.state.cache)
  buffers = vim.tbl_filter(vim.api.nvim_buf_is_valid, buffers)
  table.sort(buffers)

  local type_text = { add = 'Add', change = 'Change', delete = 'Delete' }

  local res = {}
  for _, buf_id in ipairs(buffers) do
    local filename = vim.api.nvim_buf_get_name(buf_id)
    local buf_lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
    for _, h in ipairs(H.state.cache[buf_id].hunks) do
      local text = type_text[h.type]
      local entry = { bufnr = buf_id, filename = filename, type = text:sub(1, 1), text = text }
      entry.lnum, entry.end_lnum = get_hunk_buf_range(h)
      -- Make 'add' and 'change' hunks represent actual buffer regions
      entry.col, entry.end_col = 1, h.type == 'delete' and 1 or buf_lines[entry.end_lnum]:len() + 1
      table.insert(res, entry)
    end
  end
  return res
end

-- Module functions -----------------------------------------------------------
M.do_hunks = function(buf_id, action, opts)
  buf_id = H.val.validate_buf_id(buf_id)
  local buf_cache = H.state.cache[buf_id]
  if buf_cache == nil then H.log.error(string.format('Buffer %d is not enabled.', buf_id)) end
  if type(buf_cache.ref_text) ~= 'string' then H.log.error(string.format('Buffer %d has no reference text.', buf_id)) end

  if not (action == 'apply' or action == 'reset' or action == 'yank') then
    H.log.error('`action` should be one of "apply", "reset", "yank".')
  end

  local default_opts = { line_start = 1, line_end = vim.api.nvim_buf_line_count(buf_id), register = vim.v.register }
  opts = vim.tbl_deep_extend('force', default_opts, opts or {})
  local line_start, line_end = H.val.validate_target_lines(buf_id, opts.line_start, opts.line_end)
  if type(opts.register) ~= 'string' then H.log.error('`opts.register` should be string.') end

  local hunks = get_hunks_in_range(buf_cache.hunks, line_start, line_end)
  if #hunks == 0 then return H.log.notify('No hunks to ' .. action, 'INFO') end
  if action == 'apply' then get_active_source(buf_cache).apply_hunks(buf_id, hunks) end
  if action == 'reset' then reset_hunks(buf_id, hunks) end
  if action == 'yank' then yank_hunks_ref(buf_cache.ref_text, hunks, opts.register) end
end

M.goto_hunk = function(direction, opts)
  local buf_id = vim.api.nvim_get_current_buf()
  local buf_cache = H.state.cache[buf_id]
  if buf_cache == nil then H.log.error(string.format('Buffer %d is not enabled.', buf_id)) end

  if not vim.tbl_contains({ 'first', 'prev', 'next', 'last' }, direction) then
    H.log.error('`direction` should be one of "first", "prev", "next", "last".')
  end

  local default_wrap = buf_cache.config.options.wrap_goto
  local default_opts = { n_times = vim.v.count1, line_start = vim.fn.line('.'), wrap = default_wrap }
  opts = vim.tbl_deep_extend('force', default_opts, opts or {})
  if not (type(opts.n_times) == 'number' and opts.n_times >= 1) then
    H.log.error('`opts.n_times` should be positive number.')
  end
  if type(opts.line_start) ~= 'number' then H.log.error('`opts.line_start` should be number.') end
  if type(opts.wrap) ~= 'boolean' then H.log.error('`opts.wrap` should be boolean.') end

  -- Prepare ranges to iterate.
  local ranges = get_contiguous_hunk_ranges(buf_cache.hunks)
  if #ranges == 0 then return H.log.notify('No hunks to go to', 'INFO') end

  -- Iterate
  local res_ind, did_wrap = iterate_hunk_ranges(ranges, direction, opts)
  if res_ind == nil then return H.log.notify('No hunk ranges in direction ' .. vim.inspect(direction), 'INFO') end
  local res_line = ranges[res_ind].from
  if did_wrap then H.log.notify('Wrapped around edge in direction ' .. vim.inspect(direction), 'INFO') end

  -- Add to jumplist
  vim.cmd([[normal! m']])

  -- Jump
  local _, col = vim.fn.getline(res_line):find('^%s*')
  vim.api.nvim_win_set_cursor(0, { res_line, col })

  -- Open just enough folds
  vim.cmd('normal! zv')

  -- Update hunk_idx in summary
  buf_cache.summary.hunk_idx = res_ind
  vim.b[buf_id].minidiff_summary = buf_cache.summary
end

M.operator = function(mode)
  local buf_id = vim.api.nvim_get_current_buf()
  if H.config.is_disabled(buf_id) then return '' end

  if mode == 'apply' or mode == 'reset' or mode == 'yank' then
    H.state.operator_cache = { action = mode, win_view = vim.fn.winsaveview(), register = vim.v.register }
    vim.o.operatorfunc = 'v:lua.MiniDiff.operator'
    return 'g@'
  end
  local cache = H.state.operator_cache

  -- NOTE: Using `[` / `]` marks also works in Visual mode as because it is
  -- executed as part of `g@`, which treats visual selection as a result of
  -- Operator-pending mode mechanics (for which visual selection is allowed to
  -- define motion/textobject). The downside is that it sets 'operatorfunc',
  -- but the upside is that it is "dot-repeatable" (for relative selection).
  local opts = { line_start = vim.fn.line("'["), line_end = vim.fn.line("']"), register = cache.register }
  if opts.line_end < opts.line_start then return H.log.notify('Not a proper textobject', 'INFO') end
  M.do_hunks(buf_id, cache.action, opts)

  -- Restore window view for "apply" (as buffer text should not have changed)
  if cache.action == 'apply' and cache.win_view ~= nil then
    vim.fn.winrestview(cache.win_view)
    -- NOTE: Restore only once because during dot-repeat it is not up to date
    cache.win_view = nil
  end
  return ''
end

M.textobject = function()
  local buf_id = vim.api.nvim_get_current_buf()
  local buf_cache = H.state.cache[buf_id]
  if buf_cache == nil or H.config.is_disabled(buf_id) then H.log.error('Current buffer is not enabled.') end

  -- Get hunk range under cursor
  local cur_line = vim.fn.line('.')
  local regions, cur_region = get_contiguous_hunk_ranges(buf_cache.hunks), nil
  for _, r in ipairs(regions) do
    if r.from <= cur_line and cur_line <= r.to then cur_region = r end
  end
  if cur_region == nil then return H.log.notify('No hunk range under cursor', 'INFO') end

  -- Select target region
  local is_visual = vim.tbl_contains({ 'v', 'V', '\22' }, vim.fn.mode())
  if is_visual then vim.cmd('normal! \27') end
  vim.cmd(string.format('normal! %dGV%dG', cur_region.from, cur_region.to))
end

M.export = function(format, opts)
  opts = vim.tbl_deep_extend('force', { scope = 'all' }, opts or {})
  if format == 'qf' then return export_qf(opts) end
  H.log.error('`format` should be one of "qf".')
end

M.fold_between_hunks = function(buf_id, opts)
  buf_id = H.val.validate_buf_id(buf_id)
  local buf_cache = H.state.cache[buf_id]
  if buf_cache == nil then H.log.error(string.format('Buffer %d is not enabled.', buf_id)) end

  -- Default context: 3 lines around each hunk
  local default_opts = { context = 2 }
  opts = vim.tbl_deep_extend('force', default_opts, opts or {})
  local context = opts.context

  local ranges = get_contiguous_hunk_ranges(buf_cache.hunks)
  if #ranges == 0 then return H.log.notify('No hunks to fold around', 'INFO') end

  local line_count = vim.api.nvim_buf_line_count(buf_id)
  local folds = {}

  -- Fold from start of file to first hunk (minus context)
  local first_fold_end = ranges[1].from - context - 1
  if first_fold_end >= 1 then
    table.insert(folds, { 1, first_fold_end })
  end

  -- Fold between consecutive hunks
  for i = 1, #ranges - 1 do
    local fold_start = ranges[i].to + context + 1
    local fold_end = ranges[i + 1].from - context - 1
    if fold_start <= fold_end then
      table.insert(folds, { fold_start, fold_end })
    end
  end

  -- Fold from last hunk (plus context) to end of file
  local last_fold_start = ranges[#ranges].to + context + 1
  if last_fold_start <= line_count then
    table.insert(folds, { last_fold_start, line_count })
  end

  -- Create and close folds
  for _, fold in ipairs(folds) do
    vim.cmd(string.format('%d,%dfold', fold[1], fold[2]))
  end
end

-- Export helper for float feature
M.get_contiguous_hunk_ranges = get_contiguous_hunk_ranges

return M
