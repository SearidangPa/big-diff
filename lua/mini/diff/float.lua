local H = {
  state = require('mini.diff.state'),
  val = require('mini.diff.utils_val'),
  hunk = require('mini.diff.hunk'),
}

local M = {}

-- Internal helpers ------------------------------------------------------------

local should_show_float = function(buf_id)
  -- Hide float in non-editing UI buffers
  -- - quickfix/location-list windows
  -- - prompt buffers (Telescope/Snacks/etc.)
  -- - Snacks picker windows
  local bt = vim.bo[buf_id].buftype
  if bt == 'quickfix' or bt == 'prompt' then return false end

  local ft = vim.bo[buf_id].filetype
  if ft == 'snacks_picker_list' or ft == 'snacks_picker_input' then return false end

  return true
end

local clear_float_content = function()
  if not (H.state.float_buf and vim.api.nvim_buf_is_valid(H.state.float_buf)) then return end
  vim.bo[H.state.float_buf].modifiable = true
  vim.api.nvim_buf_set_lines(H.state.float_buf, 0, -1, false, { '' })
  vim.bo[H.state.float_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(H.state.float_buf, H.state.ns_id.float, 0, -1)
end

local create_float_buf = function()
  if H.state.float_buf and vim.api.nvim_buf_is_valid(H.state.float_buf) then return H.state.float_buf end

  H.state.float_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[H.state.float_buf].buftype = 'nofile'
  vim.bo[H.state.float_buf].bufhidden = 'hide'
  vim.bo[H.state.float_buf].swapfile = false
  vim.bo[H.state.float_buf].modifiable = false
  return H.state.float_buf
end

local create_float_win = function(buf_id)
  local buf_cache = H.state.cache[buf_id]

  local float_config = (buf_cache and buf_cache.config or _G.MiniDiff.config).view.float
  local float_buf = create_float_buf()

  -- Calculate height based on hunks
  local hunks = buf_cache and buf_cache.hunks or {}
  local ranges = H.hunk.get_contiguous_hunk_ranges(hunks)
  local height = math.max(#ranges + 1, 1) -- +1 for potential cursor line between hunks

  local win_opts = {
    relative = 'editor',
    width = float_config.width,
    height = height,
    row = 2,
    col = vim.o.columns - float_config.width,
    style = 'minimal',
    border = 'rounded',
    zindex = float_config.zindex,
    focusable = false,
  }

  if H.state.float_win and vim.api.nvim_win_is_valid(H.state.float_win) then
    vim.api.nvim_win_set_config(H.state.float_win, win_opts)
  else
    H.state.float_win = vim.api.nvim_open_win(float_buf, false, win_opts)
    vim.wo[H.state.float_win].winblend = float_config.winblend
    vim.wo[H.state.float_win].cursorline = false
    vim.wo[H.state.float_win].number = false
    vim.wo[H.state.float_win].relativenumber = false
    vim.wo[H.state.float_win].winhighlight = 'Normal:MiniDiffFloatNormal'
  end
end

local get_cursor_hunk_position = function(ranges, cursor_line)
  if #ranges == 0 then return { type = 'no_hunks' } end

  if cursor_line < ranges[1].from then return { type = 'before_all' } end
  if cursor_line > ranges[#ranges].to then return { type = 'after_all' } end

  -- Find closest (contiguous) hunk range relative to cursor.
  -- Linear scan is enough because number of hunks is typically small.
  for i, range in ipairs(ranges) do
    if cursor_line >= range.from and cursor_line <= range.to then
      return { type = 'on', idx = i }
    end

    local next_range = ranges[i + 1]
    if next_range and cursor_line > range.to and cursor_line < next_range.from then
      return { type = 'between', before = i, after = i + 1 }
    end
  end

  return { type = 'after_all' }
end

local get_cursor_hunk_bucket = function(ranges, cursor_line)
  local pos = get_cursor_hunk_position(ranges, cursor_line)
  if pos.type == 'on' then return string.format('on:%d', pos.idx) end
  if pos.type == 'between' then return string.format('between:%d', pos.before) end
  return pos.type
end

local get_hunk_type_for_range = function(hunks, range)
  -- Find the dominant hunk type for a contiguous range
  for _, hunk in ipairs(hunks) do
    local hunk_from = math.max(hunk.buf_start, 1)
    local hunk_to = hunk_from + math.max(hunk.buf_count, 1) - 1
    if hunk_from >= range.from and hunk_to <= range.to then
      -- Prefer 'change' type if mixed
      if hunk.type == 'change' then return 'change' end
    end
  end
  -- Return type of first hunk in range
  for _, hunk in ipairs(hunks) do
    local hunk_from = math.max(hunk.buf_start, 1)
    if hunk_from >= range.from and hunk_from <= range.to then
      return hunk.type
    end
  end
  return 'add'
end

local update_float_content = function(buf_id)
  if not H.state.float_enabled then return end
  if not H.state.float_buf or not vim.api.nvim_buf_is_valid(H.state.float_buf) then return end

  local buf_cache = H.state.cache[buf_id]
  if buf_cache == nil then return clear_float_content() end

  local ranges = H.hunk.get_contiguous_hunk_ranges(buf_cache.hunks)
  local cursor_line = vim.fn.line('.')
  local cursor_pos = get_cursor_hunk_position(ranges, cursor_line)
  H.state.float_cursor_bucket[buf_id] = get_cursor_hunk_bucket(ranges, cursor_line)

  local lines = {}
  local highlights = {}

  if #ranges == 0 then
    table.insert(lines, ' No hunks')
  else
    -- Determine where to insert cursor indicator
    local cursor_line_idx = nil
    if cursor_pos.type == 'before_all' then
      cursor_line_idx = 0
    elseif cursor_pos.type == 'between' then
      cursor_line_idx = cursor_pos.before
    elseif cursor_pos.type == 'after_all' then
      cursor_line_idx = #ranges
    end

    local show_in_between_cursor = function()
      -- Insert padded cursor indicator and highlight it
      local cursor_text = '  ---'
      table.insert(lines, cursor_text)
      table.insert(highlights, {
        line = #lines - 1,
        col_start = #cursor_text - 3,
        col_end = #cursor_text,
        hl = 'MiniDiffFloatCursorText',
      })
    end

    for i, range in ipairs(ranges) do
      -- Insert cursor line before this hunk if needed
      if cursor_line_idx and cursor_line_idx == i - 1 then
        show_in_between_cursor()
        cursor_line_idx = nil -- Mark as inserted
      end

      local hunk_type = get_hunk_type_for_range(buf_cache.hunks, range)
      local is_current = cursor_pos.type == 'on' and cursor_pos.idx == i
      local prefix = ' '
      local line = string.format('%s %s', prefix, hunk_type)
      table.insert(lines, line)

      local line_idx = #lines - 1
      -- Highlight current hunk line background
      if is_current then
        table.insert(highlights, {
          line = line_idx,
          col_start = 2,
          col_end = #line,
          hl = 'MiniDiffFloatCursorText',
        })
      end

      -- Highlight hunk type
      local hl_group = 'MiniDiffFloat' .. hunk_type:sub(1, 1):upper() .. hunk_type:sub(2)
      table.insert(highlights, {
        line = line_idx,
        col_start = 2,
        col_end = #line,
        hl = hl_group,
      })
    end

    -- Insert cursor line after all hunks if needed
    if cursor_line_idx and cursor_line_idx == #ranges then
      show_in_between_cursor()
    end
  end

  -- Update buffer content
  vim.bo[H.state.float_buf].modifiable = true
  vim.api.nvim_buf_set_lines(H.state.float_buf, 0, -1, false, lines)
  vim.bo[H.state.float_buf].modifiable = false

  -- Apply highlights
  local ns = H.state.ns_id.float
  vim.api.nvim_buf_clear_namespace(H.state.float_buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    local extmark_opts = { strict = false }
    if hl.line_hl then
      extmark_opts.line_hl_group = hl.line_hl
    else
      extmark_opts.end_col = hl.col_end
      extmark_opts.hl_group = hl.hl
      extmark_opts.priority = 100
    end
    vim.api.nvim_buf_set_extmark(H.state.float_buf, ns, hl.line, hl.col_start or 0, extmark_opts)
  end

  -- Update window size
  create_float_win(buf_id)
end

local schedule_float_update = function(buf_id)
  local buf_cache = H.state.cache[buf_id]
  local throttle_ms = (buf_cache and buf_cache.config or _G.MiniDiff.config).view.float.throttle_ms

  -- Use a persistent libuv timer and restart it on every CursorMoved.
  -- Creating/closing timers on every cursor move can make `j`/`k` feel slow.
  local timer = H.state.timer_float_update
  if timer == nil then
    -- Use `vim.uv` if available (Neovim>=0.10), fallback to `vim.loop`.
    local uv = vim.uv or vim.loop
    timer = uv.new_timer()
    H.state.timer_float_update = timer
  end

  assert(timer ~= nil, 'Failed to create timer for float updates')
  timer:stop()
  timer:start(throttle_ms, 0, function()
    -- Timer callback runs off the main loop; schedule Neovim API usage.
    vim.schedule(function()
      if vim.api.nvim_get_current_buf() == buf_id then
        update_float_content(buf_id)
      end
    end)
  end)
end

local teardown_float_autocmds = function()
  if H.state.float_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, H.state.float_augroup)
    H.state.float_augroup = nil
  end

  if H.state.timer_float_update then
    H.state.timer_float_update:stop()
    H.state.timer_float_update:close()
    H.state.timer_float_update = nil
  end

  H.state.float_cursor_bucket = {}
end

local setup_float_autocmds = function()
  if H.state.float_augroup then return end

  H.state.float_augroup = vim.api.nvim_create_augroup('MiniDiffFloat', { clear = true })

  local update_cur_buf = function()
    if not H.state.float_enabled then return end

    local buf_id = vim.api.nvim_get_current_buf()
    if not should_show_float(buf_id) then return M.close() end

    H.state.float_buf_id = buf_id

    create_float_win(buf_id)
    if H.state.cache[buf_id] == nil then return clear_float_content() end
    update_float_content(buf_id)
  end

  vim.api.nvim_create_autocmd({ 'BufEnter', 'WinEnter' }, {
    group = H.state.float_augroup,
    callback = vim.schedule_wrap(update_cur_buf),
    desc = 'Update diff float on enter',
  })

  vim.api.nvim_create_autocmd('CursorMoved', {
    group = H.state.float_augroup,
    callback = function()
      if not H.state.float_enabled then return end

      local buf_id = vim.api.nvim_get_current_buf()
      if not should_show_float(buf_id) then return end

      H.state.float_buf_id = buf_id

      local buf_cache = H.state.cache[buf_id]
      if buf_cache == nil then return end

      local ranges = H.hunk.get_contiguous_hunk_ranges(buf_cache.hunks)
      local cursor_line = vim.fn.line('.')
      local bucket = get_cursor_hunk_bucket(ranges, cursor_line)
      if H.state.float_cursor_bucket[buf_id] == bucket then return end

      H.state.float_cursor_bucket[buf_id] = bucket
      schedule_float_update(buf_id)
    end,
    desc = 'Update diff float on cursor move',
  })
end

-- Public API ------------------------------------------------------------------

M.close = function()
  if H.state.float_win and vim.api.nvim_win_is_valid(H.state.float_win) then
    vim.api.nvim_win_close(H.state.float_win, true)
  end
  H.state.float_win = nil
end

M.open = function(buf_id)
  buf_id = H.val.validate_buf_id(buf_id)

  if H.state.float_enabled then return end
  H.state.float_enabled = true
  setup_float_autocmds()
  H.state.float_buf_id = buf_id
  create_float_win(buf_id)
  if H.state.cache[buf_id] == nil then return clear_float_content() end
  return update_float_content(buf_id)
end

M.toggle = function(buf_id)
  buf_id = H.val.validate_buf_id(buf_id)

  H.state.float_enabled = not H.state.float_enabled
  if H.state.float_enabled then
    setup_float_autocmds()
    H.state.float_buf_id = buf_id
    create_float_win(buf_id)
    if H.state.cache[buf_id] == nil then return clear_float_content() end
    return update_float_content(buf_id)
  end

  teardown_float_autocmds()
  clear_float_content()
  M.close()
end

-- Exposed for init.lua usage
M.clear_content = clear_float_content

return M
