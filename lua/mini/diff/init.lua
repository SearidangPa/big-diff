local H = {
  log = require('mini.diff.utils_log'),
  val = require('mini.diff.utils_val'),
  vim = require('mini.diff.utils_vim'),
  state = require('mini.diff.state'),
  config = require('mini.diff.config'),
  sources = require('mini.diff.sources'),
  hunk = require('mini.diff.hunk'),
  viz = require('mini.diff.viz'),
}

local MiniDiff = {}

-- Public API -----------------------------------------------------------------
MiniDiff.setup = function(config)
  -- Export module
  _G.MiniDiff = MiniDiff

  -- Setup config
  config = H.config.setup_config(config)

  -- Apply config
  MiniDiff.config = config

  -- Make mappings
  local mappings = config.mappings
  local rhs_apply = function() return MiniDiff.operator('apply') end
  H.vim.map({ 'n', 'x' }, mappings.apply, rhs_apply, { expr = true, desc = 'Apply hunks' })
  local rhs_reset = function() return MiniDiff.operator('reset') end
  H.vim.map({ 'n', 'x' }, mappings.reset, rhs_reset, { expr = true, desc = 'Reset hunks' })

  local is_tobj_conflict = mappings.textobject == mappings.apply or mappings.textobject == mappings.reset
  local modes = is_tobj_conflict and { 'o' } or { 'x', 'o' }
  H.vim.map(modes, mappings.textobject, '<Cmd>lua MiniDiff.textobject()<CR>', { desc = 'Hunk range textobject' })

  --stylua: ignore start
  H.vim.map({ 'n', 'x' }, mappings.goto_first, "<Cmd>lua MiniDiff.goto_hunk('first')<CR>", { desc = 'First hunk' })
  H.vim.map('o', mappings.goto_first, "V<Cmd>lua MiniDiff.goto_hunk('first')<CR>", { desc = 'First hunk' })
  H.vim.map({ 'n', 'x' }, mappings.goto_prev, "<Cmd>lua MiniDiff.goto_hunk('prev')<CR>", { desc = 'Previous hunk' })
  H.vim.map('o', mappings.goto_prev, "V<Cmd>lua MiniDiff.goto_hunk('prev')<CR>", { desc = 'Previous hunk' })
  H.vim.map({ 'n', 'x' }, mappings.goto_next, "<Cmd>lua MiniDiff.goto_hunk('next')<CR>", { desc = 'Next hunk' })
  H.vim.map('o', mappings.goto_next, "V<Cmd>lua MiniDiff.goto_hunk('next')<CR>", { desc = 'Next hunk' })
  H.vim.map({ 'n', 'x' }, mappings.goto_last, "<Cmd>lua MiniDiff.goto_hunk('last')<CR>", { desc = 'Last hunk' })
  H.vim.map('o', mappings.goto_last, "V<Cmd>lua MiniDiff.goto_hunk('last')<CR>", { desc = 'Last hunk' })
  H.vim.map('n', mappings.toggle_float, '<Cmd>lua MiniDiff.toggle_float()<CR>', { desc = 'Toggle diff float' })
  --stylua: ignore end

  -- Register decoration provider
  H.viz.set_decoration_provider(H.state.ns_id.viz, H.state.ns_id.overlay)

  -- Define behavior
  local gr = vim.api.nvim_create_augroup('MiniDiff', {})
  local au = function(event, pattern, callback, desc)
    vim.api.nvim_create_autocmd(event, { group = gr, pattern = pattern, callback = callback, desc = desc })
  end

  -- NOTE: Try auto enabling buffer on every `BufEnter` to not have `:edit`
  -- disabling buffer, as it calls `on_detach()` from buffer watcher
  local auto_enable = vim.schedule_wrap(function(data)
    if H.state.cache[data.buf] ~= nil or H.config.is_disabled(data.buf) then return end
    local buf = data.buf
    if not (vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].buftype == '' and vim.bo[buf].buflisted) then return end
    if not H.vim.is_buf_text(buf) then return end
    MiniDiff.enable(buf)
  end)

  au('BufEnter', '*', auto_enable, 'Enable diff')

  au('VimResized', '*', function()
    H.viz.on_resize()
    for buf_id, _ in pairs(H.state.cache) do
      if vim.api.nvim_buf_is_valid(buf_id) then
        MiniDiff.schedule_diff_update(buf_id, 0)
      end
    end
  end, 'Track Neovim resizing')

  au('ColorScheme', '*', function()
    H.viz.create_default_hl()
    H.viz.clear_blended_hl_cache()
  end, 'Ensure colors')

  for _, buf_id in ipairs(vim.api.nvim_list_bufs()) do
    auto_enable({ buf = buf_id })
  end

  -- Create default highlighting
  H.viz.create_default_hl()
end

MiniDiff.enable = function(buf_id)
  buf_id = H.val.validate_buf_id(buf_id)

  -- Don't enable more than once
  if H.state.cache[buf_id] ~= nil or H.config.is_disabled(buf_id) then return end

  -- Ensure buffer is loaded (to have up to date lines returned)
  H.vim.buf_ensure_loaded(buf_id)

  -- Register enabled buffer with cached data for performance
  local update_buf_cache = function(b_id)
    local new_cache = H.state.cache[b_id] or {}

    local buf_config = H.config.get_config({}, b_id)
    new_cache.config = buf_config
    new_cache.extmark_opts = H.viz.convert_view_to_extmark_opts(buf_config.view)
    new_cache.source = H.config.normalize_source(buf_config.source or { H.sources.gen_source.git() })
    new_cache.source_id = new_cache.source_id or 1

    new_cache.hunks = new_cache.hunks or {}
    new_cache.summary = new_cache.summary or {}
    new_cache.viz_lines = new_cache.viz_lines or {}

    new_cache.overlay = H.state.overlay
    new_cache.overlay_lines = new_cache.overlay_lines or {}

    H.state.cache[b_id] = new_cache
  end
  update_buf_cache(buf_id)

  -- Add buffer watchers
  vim.api.nvim_buf_attach(buf_id, false, {
    -- Called on every text change (`:h nvim_buf_lines_event`)
    on_lines = function(_, _, _, from_line, _, to_line)
      local buf_cache = H.state.cache[buf_id]
      -- Properly detach if diffing is disabled
      if buf_cache == nil then return true end
      MiniDiff.schedule_diff_update(buf_id, buf_cache.config.delay.text_change)
    end,

    -- Called when buffer content is changed outside of current session
    on_reload = function() MiniDiff.schedule_diff_update(buf_id, 0) end,

    -- Called when buffer is unloaded from memory (`:h nvim_buf_detach_event`),
    -- **including** `:edit` command
    on_detach = function() MiniDiff.disable(buf_id) end,
  })

  -- Add buffer autocommands
  local augroup = vim.api.nvim_create_augroup('MiniDiffBuffer' .. buf_id, { clear = true })
  H.state.cache[buf_id].augroup = augroup

  local buf_update = vim.schedule_wrap(function() update_buf_cache(buf_id) end)
  local bufwinenter_opts = { group = augroup, buffer = buf_id, callback = buf_update, desc = 'Update buffer cache' }
  vim.api.nvim_create_autocmd('BufWinEnter', bufwinenter_opts)

  local reset_if_enabled = vim.schedule_wrap(function(data)
    if H.state.cache[data.buf] == nil then return end
    MiniDiff.disable(data.buf)
    MiniDiff.enable(data.buf)
  end)
  local bufrename_opts = { group = augroup, buffer = buf_id, callback = reset_if_enabled, desc = 'Reset on rename' }
  -- NOTE: `BufFilePost` does not look like a proper event, but it (yet) works
  vim.api.nvim_create_autocmd('BufFilePost', bufrename_opts)

  local buf_disable = function() MiniDiff.disable(buf_id) end
  local bufdelete_opts = { group = augroup, buffer = buf_id, callback = buf_disable, desc = 'Disable on delete' }
  vim.api.nvim_create_autocmd('BufDelete', bufdelete_opts)


  -- Try attaching source after all necessary watchers are set up. It is needed
  -- to still have them set up if first source of many returned `false`.
  local active_source = H.state.cache[buf_id].source[H.state.cache[buf_id].source_id] or {}
  local attach_output = active_source.attach(buf_id)
  if attach_output == false then MiniDiff.fail_attach(buf_id) end
end

MiniDiff.close_float = function()
  if H.state.float_win and vim.api.nvim_win_is_valid(H.state.float_win) then
    vim.api.nvim_win_close(H.state.float_win, true)
  end
  H.state.float_win = nil
end

local clear_float_content = function()
  if not (H.state.float_buf and vim.api.nvim_buf_is_valid(H.state.float_buf)) then return end
  vim.bo[H.state.float_buf].modifiable = true
  vim.api.nvim_buf_set_lines(H.state.float_buf, 0, -1, false, { '' })
  vim.bo[H.state.float_buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(H.state.float_buf, H.state.ns_id.float, 0, -1)
end

MiniDiff.disable = function(buf_id)
  buf_id = H.val.validate_buf_id(buf_id)

  local buf_cache = H.state.cache[buf_id]
  if buf_cache == nil then return end


  H.state.cache[buf_id] = nil
  H.state.ts_cache[buf_id] = nil

  pcall(vim.api.nvim_del_augroup_by_id, buf_cache.augroup)
  vim.b[buf_id].minidiff_summary = nil
  H.viz.clear_all_diff(buf_id)

  local active_source = buf_cache.source[buf_cache.source_id] or {}
  pcall(active_source.detach, buf_id)
end

MiniDiff.toggle = function(buf_id)
  buf_id = H.val.validate_buf_id(buf_id)
  if H.state.cache[buf_id] ~= nil then return MiniDiff.disable(buf_id) end
  return MiniDiff.enable(buf_id)
end

MiniDiff.toggle_overlay = function()
  H.state.overlay = not H.state.overlay

  for buf_id, buf_cache in pairs(H.state.cache) do
    if vim.api.nvim_buf_is_valid(buf_id) then
      buf_cache.overlay = H.state.overlay
      H.viz.clear_all_diff(buf_id)
      MiniDiff.schedule_diff_update(buf_id, 0)
    end
  end
end

-- Options helpers ------------------------------------------------------------

-- Toggle ignoring whitespace globally for all enabled buffers.
--
-- This changes `MiniDiff.config.options.ignore_whitespace` and refreshes config
-- cache for all enabled buffers.
MiniDiff.toggle_ignore_whitespace = function()
  return MiniDiff.set_ignore_whitespace(not MiniDiff.get_ignore_whitespace())
end

-- Set ignoring whitespace globally. Returns the new value.
MiniDiff.set_ignore_whitespace = function(value)
  if type(value) ~= 'boolean' then return H.val.error('`value` should be boolean.') end

  MiniDiff.config.options.ignore_whitespace = value

  -- Refresh buffer caches (to pick up new global config) and recompute diffs
  for buf_id, buf_cache in pairs(H.state.cache) do
    if vim.api.nvim_buf_is_valid(buf_id) then
      local buf_config = H.config.get_config({}, buf_id)
      buf_cache.config = buf_config
      buf_cache.extmark_opts = H.viz.convert_view_to_extmark_opts(buf_config.view)
      buf_cache.source = H.config.normalize_source(buf_config.source or { H.sources.gen_source.git() })

      H.viz.clear_all_diff(buf_id)
      MiniDiff.schedule_diff_update(buf_id, 0)
    end
  end

  return value
end

-- Get current global ignore whitespace setting.
MiniDiff.get_ignore_whitespace = function()
  return MiniDiff.config.options.ignore_whitespace == true
end

-- Float window helpers -------------------------------------------------------
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

  local float_config = (buf_cache and buf_cache.config or MiniDiff.config).view.float
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

  -- Check if cursor is before all hunks
  if cursor_line < ranges[1].from then
    return { type = 'before_all' }
  end

  -- Check if cursor is after all hunks
  if cursor_line > ranges[#ranges].to then
    return { type = 'after_all' }
  end

  -- Check if cursor is on a hunk or between hunks
  for i, range in ipairs(ranges) do
    if cursor_line >= range.from and cursor_line <= range.to then
      return { type = 'on', idx = i }
    end
    if i < #ranges and cursor_line > range.to and cursor_line < ranges[i + 1].from then
      return { type = 'between', before = i, after = i + 1 }
    end
  end

  return { type = 'after_all' }
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
      -- insert 4 empty spaces so that we can insert the cursor symbol in the middle
      -- also highlight it
      local cursor_text = '   >'
      table.insert(lines, cursor_text)
      table.insert(highlights, {
        line = #lines - 1,
        col_start = #cursor_text - 1,
        col_end = #cursor_text,
        hl = 'MiniDiffFloatCursor',
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
          line_hl = 'MiniDiffFloatCursor',
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
  local throttle_ms = (buf_cache and buf_cache.config or MiniDiff.config).view.float.throttle_ms

  -- Use a persistent libuv timer and restart it on every CursorMoved.
  -- Creating/closing timers on every cursor move can make `j`/`k` feel slow.
  local timer = H.state.timer_float_update
  if timer == nil then
    -- Use `vim.uv` if available (Neovim>=0.10), fallback to `vim.loop`.
    local uv = vim.uv or vim.loop
    timer = uv.new_timer()
    H.state.timer_float_update = timer
  end

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
end

local setup_float_autocmds = function()
  if H.state.float_augroup then return end

  H.state.float_augroup = vim.api.nvim_create_augroup('MiniDiffFloat', { clear = true })

  local update_cur_buf = function()
    if not H.state.float_enabled then return end

    local buf_id = vim.api.nvim_get_current_buf()
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
      H.state.float_buf_id = buf_id
      schedule_float_update(buf_id)
    end,
    desc = 'Update diff float on cursor move',
  })
end

MiniDiff.open_float = function(buf_id)
  buf_id = H.val.validate_buf_id(buf_id)

  if H.state.float_enabled then return end
  H.state.float_enabled = true
  setup_float_autocmds()
  H.state.float_buf_id = buf_id
  create_float_win(buf_id)
  if H.state.cache[buf_id] == nil then return clear_float_content() end
  return update_float_content(buf_id)
end

MiniDiff.toggle_float = function(buf_id)
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
  MiniDiff.close_float()
end

MiniDiff.export = H.hunk.export
MiniDiff.gen_source = H.sources.gen_source
MiniDiff.operator = H.hunk.operator
MiniDiff.textobject = H.hunk.textobject
MiniDiff.goto_hunk = H.hunk.goto_hunk
MiniDiff.do_hunks = H.hunk.do_hunks

MiniDiff.get_buf_data = function(buf_id)
  buf_id = H.val.validate_buf_id(buf_id)
  local buf_cache = H.state.cache[buf_id]
  if buf_cache == nil then return nil end
  return vim.deepcopy({
    config = buf_cache.config,
    hunks = buf_cache.hunks,
    overlay = buf_cache.overlay,
    ref_text = buf_cache.ref_text,
    summary = buf_cache.summary,
  })
end

MiniDiff.set_ref_text = function(buf_id, text)
  buf_id = H.val.validate_buf_id(buf_id)
  if not (type(text) == 'table' or type(text) == 'string') then H.log.error('`text` should be either string or array.') end
  if type(text) == 'table' then text = #text > 0 and table.concat(text, '\n') or nil end

  -- Enable if not already enabled
  if H.state.cache[buf_id] == nil then MiniDiff.enable(buf_id) end
  if H.state.cache[buf_id] == nil then H.log.error('Can not set reference text for not enabled buffer.') end

  -- Appending '\n' makes more intuitive diffs at end-of-file
  if text ~= nil and string.sub(text, -1) ~= '\n' then text = text .. '\n' end
  if text == nil then
    H.viz.clear_all_diff(buf_id)
    vim.cmd('redraw')
  end

  -- Invalidate and eagerly rebuild treesitter cache
  -- (Must be done here, not in decoration provider due to E565)
  H.state.ts_cache[buf_id] = nil
  if text ~= nil then
    local lang = vim.bo[buf_id].filetype
    if lang ~= '' then
      local resolved_lang = vim.treesitter.language.get_lang(lang) or lang
      H.state.ts_cache[buf_id] = H.viz.parse_ref_text_ts(buf_id, text, resolved_lang)
    end
  end

  -- Immediately update diff
  H.state.cache[buf_id].ref_text = text
  MiniDiff.schedule_diff_update(buf_id, 0)
end

MiniDiff.fail_attach = function(buf_id)
  buf_id = H.val.validate_buf_id(buf_id)

  -- Do nothing if there was no attempt to enable
  local buf_cache = H.state.cache[buf_id]
  if buf_cache == nil then return end

  -- If no next source, disable buffer without calling any of `detach`
  if buf_cache.source_id >= #buf_cache.source then
    H.state.cache[buf_id].source_id = math.huge
    return MiniDiff.disable(buf_id)
  end

  -- Try attaching next source
  buf_cache.source_id = buf_cache.source_id + 1
  local active_source = buf_cache.source[buf_cache.source_id] or {}
  local attach_output = active_source.attach(buf_id)
  if attach_output == false then MiniDiff.fail_attach(buf_id) end
end

-- Update Loop ----------------------------------------------------------------
local process_scheduled_buffers = vim.schedule_wrap(function()
  for buf_id, _ in pairs(H.state.bufs_to_update) do
    MiniDiff.update_buf_diff(buf_id)
  end
  H.state.bufs_to_update = {}
end)

MiniDiff.schedule_diff_update = vim.schedule_wrap(function(buf_id, delay_ms)
  H.state.bufs_to_update[buf_id] = true
  H.state.timer_diff_update:stop()
  H.state.timer_diff_update:start(delay_ms, 0, process_scheduled_buffers)
end)

MiniDiff.update_buf_diff = vim.schedule_wrap(function(buf_id)
  -- Make early returns
  local buf_cache = H.state.cache[buf_id]
  if buf_cache == nil then return end
  if not vim.api.nvim_buf_is_valid(buf_id) then
    H.state.cache[buf_id] = nil
    return
  end
  if type(buf_cache.ref_text) ~= 'string' or H.config.is_disabled(buf_id) then
    local active_source = buf_cache.source[buf_cache.source_id] or {}
    local summary = { source_name = active_source.name, hunk_total = 0, hunk_idx = nil }
    buf_cache.hunks, buf_cache.viz_lines, buf_cache.overlay_lines, buf_cache.summary = {}, {}, {}, summary
    vim.b[buf_id].minidiff_summary = summary
    return
  end

  -- Compute diff
  local options = buf_cache.config.options
  H.state.vimdiff_opts.algorithm = options.algorithm
  H.state.vimdiff_opts.indent_heuristic = options.indent_heuristic
  H.state.vimdiff_opts.linematch = options.linematch
  H.state.vimdiff_opts.ignore_whitespace = options.ignore_whitespace

  local buf_text, buf_lines = H.vim.get_buftext(buf_id)
  local diff = vim.text.diff(buf_cache.ref_text, buf_text, H.state.vimdiff_opts)

  -- Recompute hunks with summary and draw information
  H.viz.update_hunk_data(diff, buf_cache, buf_lines)

  -- Set buffer-local variables with summary for easier external usage
  vim.b[buf_id].minidiff_summary = buf_cache.summary

  -- Request highlighting clear to be done in decoration provider
  buf_cache.needs_clear = true

  -- Trigger event for users to possibly hook into. Ensure target buffer is
  -- current (for proper `buf` in event data)
  vim.api.nvim_buf_call(buf_id, function() vim.api.nvim_exec_autocmds('User', { pattern = 'MiniDiffUpdated' }) end)

  -- Force redraw. NOTE: Using 'redraw' not always works (`<Cmd>update<CR>`
  -- from keymap with "save" source will not redraw) while 'redraw!' flickers.
  H.vim.redraw_buffer(buf_id)
end)

return MiniDiff
