local H = {
  log = require('mini.diff.utils_log'),
  vim = require('mini.diff.utils_vim'),
  val = require('mini.diff.utils_val'),
  text = require('mini.diff.utils_text'),
  state = require('mini.diff.state'),
}

local M = {}

-- Constants ------------------------------------------------------------------
-- Common extmark data for supported styles
--stylua: ignore
local style_extmark_data = {
  sign   = { hl_group_prefix = 'MiniDiffSign', field = 'sign_hl_group' },
  number = { hl_group_prefix = 'MiniDiffSign', field = 'number_hl_group' },
}

-- Suffix for overlay virtual lines to be highlighted as full line
local overlay_suffix = string.rep(' ', vim.o.columns)

-- Flag for whether to invalidate extmarks
local extmark_invalidate = vim.fn.has('nvim-0.10') == 1 and true or nil

-- Flag for whether to handle virtual lines overflow
local extmark_virt_lines_overflow = vim.fn.has('nvim-0.11') == 1 and 'scroll' or nil

-- Treesitter helpers ---------------------------------------------------------
-- Get treesitter highlights for a single reference line (from eager cache)
local get_ts_highlights_for_line = function(buf_id, line_num_in_ref)
  local ts_data = H.state.ts_cache[buf_id]
  if ts_data == nil then return nil end
  return ts_data.line_highlights[line_num_in_ref]
end

-- Get or create a blended highlight group (syntax fg + diff bg)
local get_blended_hl = function(syntax_hl, diff_type)
  local key = diff_type .. ':' .. syntax_hl
  if H.state.blended_hl_cache[key] then return H.state.blended_hl_cache[key] end

  local name = 'MiniDiffOverTS' .. diff_type .. syntax_hl:gsub('[^%w]', '')

  -- Get syntax highlight definition
  local syntax_def = vim.api.nvim_get_hl(0, { name = syntax_hl, link = false })
  if vim.tbl_isempty(syntax_def) then
    H.state.blended_hl_cache[key] = 'MiniDiffOver' .. diff_type
    return H.state.blended_hl_cache[key]
  end

  -- Get diff highlight definition
  local diff_hl = 'MiniDiffOver' .. diff_type
  local diff_def = vim.api.nvim_get_hl(0, { name = diff_hl, link = false })

  -- Create blended highlight: syntax fg + diff bg
  vim.api.nvim_set_hl(0, name, {
    fg = syntax_def.fg,
    bg = diff_def.bg,
    sp = syntax_def.sp,
    bold = syntax_def.bold,
    italic = syntax_def.italic,
    underline = syntax_def.underline,
    undercurl = syntax_def.undercurl,
    strikethrough = syntax_def.strikethrough,
  })

  H.state.blended_hl_cache[key] = name
  return name
end

-- Find treesitter highlight at a specific byte position
local find_ts_hl_at_pos = function(ts_highlights, byte_pos)
  if ts_highlights == nil then return nil end
  for _, hl in ipairs(ts_highlights) do
    if byte_pos >= hl.start_col and byte_pos < hl.end_col then
      return hl.hl_group
    end
  end
  return nil
end

-- Build a virtual line with treesitter syntax highlighting
local build_ts_virt_line = function(buf_id, line_text, ref_line_num, diff_type)
  local ts_highlights = get_ts_highlights_for_line(buf_id, ref_line_num)
  local default_hl = 'MiniDiffOver' .. diff_type

  if not ts_highlights or #ts_highlights == 0 then
    return { { line_text, default_hl } }
  end

  -- Build chunks by finding highlight at each position
  local chunks = {}
  local i = 1
  while i <= #line_text do
    local hl_group = find_ts_hl_at_pos(ts_highlights, i - 1)
    local blend_hl = hl_group and get_blended_hl(hl_group, diff_type) or default_hl

    -- Find extent of this highlight
    local j = i + 1
    while j <= #line_text do
      if find_ts_hl_at_pos(ts_highlights, j - 1) ~= hl_group then break end
      j = j + 1
    end

    table.insert(chunks, { line_text:sub(i, j - 1), blend_hl })
    i = j
  end

  return #chunks > 0 and chunks or { { line_text, default_hl } }
end

-- Simple worddiff virtual line (fallback without treesitter)
local build_worddiff_virt_line_simple = function(line, changed_parts)
  local virt_line, index = {}, 1
  for i = 1, #changed_parts do
    local part = changed_parts[i]
    if index < part[1] then
      table.insert(virt_line, { line:sub(index, part[1] - 1), 'MiniDiffOverContext' })
    end
    table.insert(virt_line, { line:sub(part[1], part[2]), 'MiniDiffOverChange' })
    index = part[2] + 1
  end
  if index <= line:len() then
    table.insert(virt_line, { line:sub(index), 'MiniDiffOverContext' })
  end
  return virt_line
end

-- Build worddiff virtual line with treesitter highlighting
local build_worddiff_virt_line_with_ts = function(buf_id, line, changed_parts, ref_line_num)
  local ts_highlights = get_ts_highlights_for_line(buf_id, ref_line_num)

  -- Mark each byte position with its diff type ('Change' or 'Context')
  local len = #line
  local diff_types = {}
  for i = 1, len do
    diff_types[i] = 'Context'
  end

  for _, part in ipairs(changed_parts) do
    for i = part[1], part[2] do
      if i <= len then diff_types[i] = 'Change' end
    end
  end

  -- If no treesitter highlights, build simple chunks
  if ts_highlights == nil or #ts_highlights == 0 then
    return build_worddiff_virt_line_simple(line, changed_parts)
  end

  -- Sort ts_highlights by position
  table.sort(ts_highlights, function(a, b) return a.start_col < b.start_col end)

  -- Build chunks by iterating through the line
  local chunks = {}
  local pos = 1

  while pos <= len do
    local current_diff = diff_types[pos]
    local current_ts = find_ts_hl_at_pos(ts_highlights, pos - 1)
    local segment_end = pos

    -- Find extent of current segment (same diff_type and syntax hl)
    while segment_end < len do
      local next_diff = diff_types[segment_end + 1]
      local next_ts = find_ts_hl_at_pos(ts_highlights, segment_end)
      if next_diff ~= current_diff or next_ts ~= current_ts then break end
      segment_end = segment_end + 1
    end

    local text = line:sub(pos, segment_end)
    local hl_group
    if current_ts then
      hl_group = get_blended_hl(current_ts, current_diff)
    else
      hl_group = 'MiniDiffOver' .. current_diff
    end

    table.insert(chunks, { text, hl_group })
    pos = segment_end + 1
  end

  return chunks
end

-- Overlay helpers ------------------------------------------------------------
local append_overlay = function(overlay_lines, l_num, data)
  local t = overlay_lines[l_num] or {}
  table.insert(t, data)
  overlay_lines[l_num] = t
end

local compute_worddiff_changed_parts = function(ref_line, buf_line)
  local ref_sliced, ref_byte_starts, ref_byte_ends = H.text.slice_line(ref_line)
  local buf_sliced, buf_byte_starts, buf_byte_ends = H.text.slice_line(buf_line)
  local diff = vim.diff(ref_sliced, buf_sliced, H.state.worddiff_opts)
  local ref_ranges, buf_ranges = {}, {}
  for i = 1, #diff do
    local d = diff[i]
    if d[2] > 0 then table.insert(ref_ranges, { ref_byte_starts[d[1]], ref_byte_ends[d[1] + d[2] - 1] }) end
    if d[4] > 0 then table.insert(buf_ranges, { buf_byte_starts[d[3]], buf_byte_ends[d[3] + d[4] - 1] }) end
  end

  return ref_ranges, buf_ranges
end

local draw_overlay_line_worddiff = function(buf_id, ns_id, row, data)
  local ref_line, buf_line, priority = data.ref_line, data.buf_line, data.priority
  local ref_line_num = data.ref_line_num
  local ref_parts, buf_parts = compute_worddiff_changed_parts(ref_line, buf_line)

  -- Show changes in reference as virtual line with treesitter + worddiff highlighting
  local virt_line = build_worddiff_virt_line_with_ts(buf_id, ref_line, ref_parts, ref_line_num)
  table.insert(virt_line, { overlay_suffix, 'MiniDiffOverContext' })

  --stylua: ignore
  local ref_opts = {
    virt_lines = { virt_line },
    virt_lines_above = true,
    virt_lines_overflow = extmark_virt_lines_overflow,
    priority = priority,
  }
  H.vim.set_extmark(buf_id, ns_id, row, 0, ref_opts)

  -- Show changes in buffer line as one whole-line highlighting with separate
  -- highlighting for changed regions on top (as priority of context is lower)
  local off = vim.bo[buf_id].bomb and (H.vim.bom_bytes[vim.bo[buf_id].fileencoding] or ''):len() or 0
  for i = 1, #buf_parts do
    local part = buf_parts[i]
    local buf_opts = { end_row = row, end_col = part[2] - off, hl_group = 'MiniDiffOverChangeBuf', priority = priority }
    H.vim.set_extmark(buf_id, ns_id, row, part[1] - 1 - off, buf_opts)
  end
  local context_opts =
  { end_row = row + 1, end_col = 0, hl_group = 'MiniDiffOverContextBuf', hl_eol = true, priority = priority - 1 }
  H.vim.set_extmark(buf_id, ns_id, row, 0, context_opts)
end

local draw_overlay_line = function(buf_id, ns_id, row, data)
  -- "Change worddif" hunk: compute word diff and show it above and over text
  if data.type == 'change_worddiff' then return draw_overlay_line_worddiff(buf_id, ns_id, row, data) end

  local opts = { priority = data.priority }

  -- "Add"/"Change" hunks highlight whole lines in affected buffer range
  if data.type ~= 'delete' then
    opts.end_row, opts.end_col, opts.hl_eol = data.to, 0, true
    opts.hl_group = data.type == 'add' and 'MiniDiffOverAdd' or 'MiniDiffOverContextBuf'
  end

  -- Process lines with treesitter highlighting if needed
  local virt_lines = data.lines
  if data.needs_ts and data.lines then
    virt_lines = {}
    for _, line_data in ipairs(data.lines) do
      local chunks = build_ts_virt_line(buf_id, line_data.ref_line, line_data.ref_line_num, line_data.diff_type)
      -- Add suffix
      table.insert(chunks, { overlay_suffix, 'MiniDiffOver' .. line_data.diff_type })
      table.insert(virt_lines, chunks)
    end
  end

  -- "Change"/"Delete" hunks show affected reference range as virtual lines
  opts.virt_lines, opts.virt_lines_above, opts.virt_lines_overflow =
      virt_lines, data.show_above, extmark_virt_lines_overflow
  H.vim.set_extmark(buf_id, ns_id, row, 0, opts)
end

local append_overlay_add = function(overlay_lines, hunk, priority)
  local data = { type = 'add', to = hunk.buf_start + hunk.buf_count - 1, priority = priority }
  append_overlay(overlay_lines, hunk.buf_start, data)
end

local append_overlay_change = function(overlay_lines, hunk, ref_lines, buf_lines, priority)
  -- For one-to-one change, show lines separately with word diff highlighted
  -- This is usually the case when `linematch` is on
  if hunk.buf_count == hunk.ref_count then
    for i = 0, hunk.ref_count - 1 do
      local ref_n, buf_n = hunk.ref_start + i, hunk.buf_start + i
      -- Defer actually computing word diff until in decoration provider as it
      -- will compute only for displayed lines
      local data = {
        type = 'change_worddiff',
        ref_line = ref_lines[ref_n],
        buf_line = buf_lines[buf_n],
        ref_line_num = ref_n,
        priority = priority,
      }
      append_overlay(overlay_lines, buf_n, data)
    end
    return
  end

  -- If not one-to-one change, show reference lines above first real one
  -- Store line data for deferred treesitter processing
  local changed_lines = {}
  for i = hunk.ref_start, hunk.ref_start + hunk.ref_count - 1 do
    table.insert(changed_lines, { ref_line = ref_lines[i], ref_line_num = i, diff_type = 'Change' })
  end
  local to = hunk.buf_start + hunk.buf_count - 1
  local data = { type = 'change', to = to, lines = changed_lines, show_above = true, priority = priority, needs_ts = true }
  append_overlay(overlay_lines, hunk.buf_start, data)
end

local append_overlay_delete = function(overlay_lines, hunk, ref_lines, priority)
  local deleted_lines = {}
  for i = hunk.ref_start, hunk.ref_start + hunk.ref_count - 1 do
    -- Store line data for deferred treesitter processing
    table.insert(deleted_lines, { ref_line = ref_lines[i], ref_line_num = i, diff_type = 'Delete' })
  end
  local l_num, show_above = math.max(hunk.buf_start, 1), hunk.buf_start == 0
  local data = { type = 'delete', lines = deleted_lines, show_above = show_above, priority = priority, needs_ts = true }
  append_overlay(overlay_lines, l_num, data)
end

-- Exported functions ---------------------------------------------------------
M.set_decoration_provider = function(ns_id_viz, ns_id_overlay)
  local on_win = function(_, _, buf_id, top, bottom)
    local buf_cache = H.state.cache[buf_id]
    if buf_cache == nil then return false end

    local viz_lines, overlay_lines = buf_cache.viz_lines, buf_cache.overlay_lines
    if buf_cache.needs_clear then
      M.clear_all_diff(buf_id)
      buf_cache.needs_clear, buf_cache.dummy_extmark = false, nil
      -- Ensure that sign column is visible even if hunks are outside of window
      -- view (matters with `signcolumn=auto`)
      if buf_cache.config.view.style == 'sign' and not vim.tbl_isempty(viz_lines) then
        local dummy_opts = { sign_text = '  ', priority = 0, right_gravity = false }
        dummy_opts.sign_hl_group, dummy_opts.cursorline_hl_group = 'SignColumn', 'CursorLineSign'
        buf_cache.dummy_extmark = vim.api.nvim_buf_set_extmark(buf_id, ns_id_viz, 0, 0, dummy_opts)
      end
    end

    local has_viz_extmarks = false
    for i = top + 1, bottom + 1 do
      if viz_lines[i] ~= nil then
        H.vim.set_extmark(buf_id, ns_id_viz, i - 1, 0, viz_lines[i])
        viz_lines[i] = nil
        has_viz_extmarks = true
      end
      if overlay_lines[i] ~= nil then
        -- Allow several overlays at one line (like for "delete" and "change")
        for j = 1, #overlay_lines[i] do
          draw_overlay_line(buf_id, ns_id_overlay, i - 1, overlay_lines[i][j])
        end
        overlay_lines[i] = nil
      end
    end

    -- Make sure to clear dummy extmark when it is not needed (otherwise it
    -- affects signcolumn for cases like `yes:2` and `auto:2`)
    if buf_cache.dummy_extmark ~= nil and has_viz_extmarks then
      vim.api.nvim_buf_del_extmark(buf_id, ns_id_viz, buf_cache.dummy_extmark)
      buf_cache.dummy_extmark = nil
    end
  end
  vim.api.nvim_set_decoration_provider(ns_id_viz, { on_win = on_win })
end

M.update_hunk_data = function(diff, buf_cache, buf_lines)
  local do_overlay = buf_cache.overlay
  local ref_lines = do_overlay and vim.split(buf_cache.ref_text, '\n') or nil

  local extmark_opts, priority = buf_cache.extmark_opts, buf_cache.config.view.priority
  local hunks, viz_lines, overlay_lines = {}, {}, {}
  local n_add, n_change, n_delete = 0, 0, 0
  local n_ranges, last_range_to = 0, -math.huge
  for i, d in ipairs(diff) do
    -- Hunk
    local n_ref, n_buf = d[2], d[4]
    local hunk_type = n_ref == 0 and 'add' or (n_buf == 0 and 'delete' or 'change')
    local hunk = { type = hunk_type, ref_start = d[1], ref_count = n_ref, buf_start = d[3], buf_count = n_buf }
    hunks[i] = hunk

    -- Hunk summary
    local hunk_n_change = math.min(n_ref, n_buf)
    n_add = n_add + n_buf - hunk_n_change
    n_change = n_change + hunk_n_change
    n_delete = n_delete + n_ref - hunk_n_change

    -- Number of contiguous ranges.
    -- NOTE: this relies on `vim.diff()` output being sorted by `buf_start`.
    local range_from = math.max(d[3], 1)
    local range_to = range_from + math.max(n_buf, 1) - 1
    n_ranges = n_ranges + ((range_from <= last_range_to + 1) and 0 or 1)
    last_range_to = math.max(last_range_to, range_to)

    -- Register lines for draw. At least one line should visualize hunk.
    local viz_ext_opts = extmark_opts[hunk_type]
    for l_num = range_from, range_to do
      -- Prefer showing "change" hunk over other types
      if viz_lines[l_num] == nil or hunk_type == 'change' then viz_lines[l_num] = viz_ext_opts end
    end

    if do_overlay then
      if hunk_type == 'add' then append_overlay_add(overlay_lines, hunk, priority) end
      if hunk_type == 'change' then append_overlay_change(overlay_lines, hunk, ref_lines, buf_lines, priority) end
      if hunk_type == 'delete' then append_overlay_delete(overlay_lines, hunk, ref_lines, priority) end
    end
  end

  buf_cache.hunks, buf_cache.viz_lines, buf_cache.overlay_lines = hunks, viz_lines, overlay_lines
  buf_cache.summary = { add = n_add, change = n_change, delete = n_delete, n_ranges = n_ranges }
  buf_cache.summary.source_name = (buf_cache.source[buf_cache.source_id] or {}).name
end

M.clear_all_diff = function(buf_id)
  H.vim.clear_namespace(buf_id, H.state.ns_id.viz, 0, -1)
  H.vim.clear_namespace(buf_id, H.state.ns_id.overlay, 0, -1)
end

M.on_resize = function()
  overlay_suffix = string.rep(' ', vim.o.columns)
  for buf_id, _ in pairs(H.state.cache) do
    if vim.api.nvim_buf_is_valid(buf_id) then
      M.clear_all_diff(buf_id)
      -- Use _G.MiniDiff.schedule_diff_update to avoid circular dependency if possible,
      -- but this function is in init.lua.
      -- However, on_resize calls schedule_diff_update.
      -- I can pass it or rely on global.
      -- The original code used H.schedule_diff_update.
      -- I'll assume init.lua binds a way to update or I'll export a function to be called by init.
      -- Actually, `on_resize` is called by an autocommand.
      -- `init.lua` sets up the autocommand.
      -- `init.lua` can define the callback: `function() require('mini.diff.viz').on_resize(); require('mini.diff').schedule_diff_update(...) end`
      -- But on_resize logic is: clear diff, then schedule update.
      -- So `on_resize` in viz should probably just clear diffs and reset overlay_suffix.
      -- And init.lua should handle the schedule update.
    end
  end
end
-- Redefine on_resize to just do what it can here, returning buf_ids to update?
-- Or just let init.lua handle the loop.
M.update_overlay_suffix = function()
  overlay_suffix = string.rep(' ', vim.o.columns)
end

M.convert_view_to_extmark_opts = function(view)
  local extmark_data = style_extmark_data[view.style]
  if extmark_data == nil then H.log.error('Style ' .. vim.inspect(view.style) .. ' is not supported.') end

  local signs = view.style == 'sign' and view.signs or {}
  local field, hl_group_prefix = extmark_data.field, extmark_data.hl_group_prefix
  --stylua: ignore
  return {
    add = { [field] = hl_group_prefix .. 'Add', sign_text = signs.add, priority = view.priority, invalidate = extmark_invalidate },
    change = { [field] = hl_group_prefix .. 'Change', sign_text = signs.change, priority = view.priority, invalidate = extmark_invalidate },
    delete = { [field] = hl_group_prefix .. 'Delete', sign_text = signs.delete, priority = view.priority, invalidate = extmark_invalidate },
  }
end

-- Parse reference text with treesitter and extract highlights per line
M.parse_ref_text_ts = function(buf_id, ref_text, lang)
  local ok, parser = pcall(vim.treesitter.get_string_parser, ref_text, lang)
  if not ok or parser == nil then return nil end

  local trees = parser:parse()
  if #trees == 0 then return nil end

  local query_ok, query = pcall(vim.treesitter.query.get, lang, 'highlights')
  if not query_ok or query == nil then return nil end

  local lines = vim.split(ref_text, '\n')
  local line_highlights = {}
  for i = 1, #lines do
    line_highlights[i] = {}
  end

  -- Iterate through all captures
  for id, node, _ in query:iter_captures(trees[1]:root(), ref_text) do
    local name = query.captures[id]
    local hl_group = '@' .. name
    local start_row, start_col, end_row, end_col = node:range()

    -- Handle single-line and multi-line captures
    if start_row == end_row then
      if line_highlights[start_row + 1] then
        table.insert(line_highlights[start_row + 1], {
          start_col = start_col,
          end_col = end_col,
          hl_group = hl_group,
        })
      end
    else
      for row = start_row, end_row do
        if line_highlights[row + 1] then
          local s = (row == start_row) and start_col or 0
          local e = (row == end_row) and end_col or #(lines[row + 1] or '')
          table.insert(line_highlights[row + 1], {
            start_col = s,
            end_col = e,
            hl_group = hl_group,
          })
        end
      end
    end
  end

  return { ref_text = ref_text, line_highlights = line_highlights }
end

--stylua: ignore
M.create_default_hl = function()
  local hi = function(name, opts)
    opts.default = true
    vim.api.nvim_set_hl(0, name, opts)
  end

  local has_core_diff_hl = vim.fn.has('nvim-0.10') == 1
  hi('MiniDiffSignAdd', { link = has_core_diff_hl and 'Added' or 'diffAdded' })
  hi('MiniDiffSignChange', { link = has_core_diff_hl and 'Changed' or 'diffChanged' })
  hi('MiniDiffSignDelete', { link = has_core_diff_hl and 'Removed' or 'diffRemoved' })
  hi('MiniDiffOverAdd', { fg = '#AED28C' })                    -- Green for additions
  hi('MiniDiffOverChangeBuf', { fg = '#AED28C' })              -- Green for buffer (new) text
  hi('MiniDiffOverContextBuf', {})
  hi('MiniDiffOverDelete', { fg = '#f38ba8', bg = '#3a1a1a' }) -- Red for deletions

  vim.api.nvim_set_hl(0, 'MiniDiffOverContext', { bg = '#451B21' })
  vim.api.nvim_set_hl(0, 'MiniDiffOverChange', { fg = '#ea9a97', bg = '#79502E' })
end

M.clear_blended_hl_cache = function()
  H.state.blended_hl_cache = {}
end

return M
