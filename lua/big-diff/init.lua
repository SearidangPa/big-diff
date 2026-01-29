-- Lazy module loading: modules are loaded on first access
local H = setmetatable({}, {
  __index = function(t, k)
    local map = {
      log = 'big-diff.utils_log',
      val = 'big-diff.utils_val',
      vim = 'big-diff.utils_vim',
      state = 'big-diff.state',
      config = 'big-diff.config',
      sources = 'big-diff.sources',
      hunk = 'big-diff.hunk',
      viz = 'big-diff.viz',
    }
    if map[k] then
      rawset(t, k, require(map[k]))
      return t[k]
    end
  end,
})

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
  --stylua: ignore end

  -- Create user commands
  vim.api.nvim_create_user_command('FoldBetweenHunk', function(cmd_opts)
    local context = cmd_opts.args ~= '' and tonumber(cmd_opts.args) or nil
    MiniDiff.fold_between_hunks(0, context and { context = context } or nil)
  end, { nargs = '?', desc = 'Fold unchanged regions between hunks' })

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
    -- Only update visible buffers immediately; defer hidden buffers
    local visible_bufs = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      visible_bufs[vim.api.nvim_win_get_buf(win)] = true
    end
    for buf_id, buf_cache in pairs(H.state.cache) do
      if vim.api.nvim_buf_is_valid(buf_id) then
        if visible_bufs[buf_id] then
          MiniDiff.schedule_diff_update(buf_id, 0)
        else
          -- Mark hidden buffers to refresh when they become visible
          buf_cache.needs_refresh_on_view = true
        end
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
    on_reload = function()
      H.vim.invalidate_buf_text_cache(buf_id)
      MiniDiff.schedule_diff_update(buf_id, 0)
    end,

    -- Called when buffer is unloaded from memory (`:h nvim_buf_detach_event`),
    -- **including** `:edit` command
    on_detach = function() MiniDiff.disable(buf_id) end,
  })

  -- Add buffer autocommands
  local augroup = vim.api.nvim_create_augroup('MiniDiffBuffer' .. buf_id, { clear = true })
  H.state.cache[buf_id].augroup = augroup

  local buf_update = vim.schedule_wrap(function()
    update_buf_cache(buf_id)
    -- Handle deferred refresh from VimResized when buffer becomes visible
    local cache = H.state.cache[buf_id]
    if cache and cache.needs_refresh_on_view then
      cache.needs_refresh_on_view = nil
      MiniDiff.schedule_diff_update(buf_id, 0)
    end
  end)
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
      -- Build treesitter cache when overlay is turned on (lazy parsing)
      if H.state.overlay and buf_cache.ref_text ~= nil and H.state.ts_cache[buf_id] == nil then
        local lang = vim.bo[buf_id].filetype
        if lang ~= '' then
          local resolved_lang = vim.treesitter.language.get_lang(lang) or lang
          H.state.ts_cache[buf_id] = H.viz.parse_ref_text_ts(buf_id, buf_cache.ref_text, resolved_lang)
        end
      end
      H.viz.clear_all_diff(buf_id)
      -- Force diff recomputation by invalidating hash (overlay state changed)
      buf_cache.buf_text_hash = nil
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
      -- Force diff recomputation by invalidating hash (diff options changed)
      buf_cache.buf_text_hash = nil
      MiniDiff.schedule_diff_update(buf_id, 0)
    end
  end

  return value
end

-- Get current global ignore whitespace setting.
MiniDiff.get_ignore_whitespace = function()
  return MiniDiff.config.options.ignore_whitespace == true
end

MiniDiff.export = H.hunk.export
MiniDiff.gen_source = H.sources.gen_source
MiniDiff.operator = H.hunk.operator
MiniDiff.textobject = H.hunk.textobject
MiniDiff.goto_hunk = H.hunk.goto_hunk
MiniDiff.do_hunks = H.hunk.do_hunks
MiniDiff.fold_between_hunks = H.hunk.fold_between_hunks

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

  -- Invalidate treesitter cache. Only rebuild if overlay is active.
  -- (Must be done here, not in decoration provider due to E565)
  H.state.ts_cache[buf_id] = nil
  if text ~= nil and H.state.overlay then
    local lang = vim.bo[buf_id].filetype
    if lang ~= '' then
      local resolved_lang = vim.treesitter.language.get_lang(lang) or lang
      H.state.ts_cache[buf_id] = H.viz.parse_ref_text_ts(buf_id, text, resolved_lang)
    end
  end

  -- Immediately update diff (invalidate hash to force recomputation)
  H.state.cache[buf_id].ref_text = text
  H.state.cache[buf_id].buf_text_hash = nil
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
  local timer = H.state.get_timer_diff_update()
  timer:stop()
  timer:start(delay_ms, 0, process_scheduled_buffers)
end)

-- Simple hash function for buffer text (djb2 algorithm)
local function hash_text(text)
  local hash = 5381
  for i = 1, #text do
    hash = ((hash * 33) + string.byte(text, i)) % 0x100000000
  end
  return hash
end

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

  -- Skip diff computation if buffer text hasn't changed (hash-based check)
  local new_hash = hash_text(buf_text)
  if buf_cache.buf_text_hash == new_hash and not buf_cache.needs_clear then
    return
  end
  buf_cache.buf_text_hash = new_hash

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
