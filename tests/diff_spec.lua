local diff = require('mini.diff')
local helpers = require('tests.helpers')

describe('mini.diff', function()
  before_each(function()
    diff.setup()
  end)

  after_each(function()
    vim.g.minidiff_disable = nil
    -- Clear all buffers
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end)

  describe('setup', function()
    it('creates global object', function()
      assert.are.same('table', type(_G.MiniDiff))
    end)

    it('applies config', function()
      diff.setup({ view = { style = 'sign' } })
      assert.are.same('sign', diff.config.view.style)
    end)
  end)

  describe('hunk detection', function()
    it('detects added lines', function()
      local buf_id = helpers.setup_buffer({ 'line1', 'line2' }, { 'line1' })
      helpers.expect_hunks(buf_id, {
        { type = 'add', buf_start = 2, buf_count = 1, ref_start = 1, ref_count = 0 }
      })
    end)

    it('detects deleted lines', function()
      local buf_id = helpers.setup_buffer({ 'line1' }, { 'line1', 'line2' })
      helpers.expect_hunks(buf_id, {
        { type = 'delete', buf_start = 1, buf_count = 0, ref_start = 2, ref_count = 1 }
      })
    end)

    it('detects changed lines', function()
      local buf_id = helpers.setup_buffer({ 'line1', 'changed' }, { 'line1', 'line2' })
      helpers.expect_hunks(buf_id, {
        { type = 'change', buf_start = 2, buf_count = 1, ref_start = 2, ref_count = 1 }
      })
    end)
  end)

  describe('hunk navigation', function()
    it('navigates hunks', function()
      local buf_id = helpers.setup_buffer(
        { 'a', 'b', 'c', 'd', 'e' },
        { 'a', 'c', 'e' }
      )
      -- Hunks: 'b' added at line 2, 'd' added at line 4

      vim.api.nvim_set_current_buf(buf_id)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })

      -- Next
      diff.goto_hunk('next')
      local cursor = vim.api.nvim_win_get_cursor(0)
      assert.are.same(2, cursor[1])

      -- Next again
      diff.goto_hunk('next')
      cursor = vim.api.nvim_win_get_cursor(0)
      assert.are.same(4, cursor[1])

      -- Prev
      diff.goto_hunk('prev')
      cursor = vim.api.nvim_win_get_cursor(0)
      assert.are.same(2, cursor[1])
    end)

    it('wraps navigation', function()
      local buf_id = helpers.setup_buffer(
        { 'a', 'b', 'c', 'd', 'e' },
        { 'a', 'c', 'e' }
      )

      vim.api.nvim_set_current_buf(buf_id)

      -- Update buffer config to enable wrapping and re-enable to apply
      local config = vim.b[buf_id].minidiff_config or {}
      config.options = { wrap_goto = true }
      vim.b[buf_id].minidiff_config = config

      diff.disable(buf_id)
      diff.set_ref_text(buf_id, { 'a', 'c', 'e' })
      helpers.wait_for_update(buf_id)

      vim.api.nvim_win_set_cursor(0, { 4, 0 }) -- On last hunk

      diff.goto_hunk('next')
      local cursor = vim.api.nvim_win_get_cursor(0)
      assert.are.same(2, cursor[1]) -- Should wrap to first
    end)
  end)

  describe('hunk operations', function()
    it('applies hunks', function()
      local mock = helpers.mock_source()
      diff.setup({ source = mock })
      local buf_id = helpers.setup_buffer({ 'line1', 'new' }, { 'line1' })

      -- Apply hunk at line 2
      diff.do_hunks(buf_id, 'apply', { line_start = 2, line_end = 2 })

      local applied = mock.get_applied_hunks()
      assert.are.same(1, #applied)
      assert.are.same('add', applied[1].type)
    end)

    it('resets hunks', function()
      local buf_id = helpers.setup_buffer({ 'line1', 'changed' }, { 'line1', 'original' })

      -- Reset hunk at line 2
      diff.do_hunks(buf_id, 'reset', { line_start = 2, line_end = 2 })

      local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
      assert.are.same({ 'line1', 'original' }, lines)
    end)

    it('text object selects hunk', function()
      local buf_id = helpers.setup_buffer({ 'line1', 'new' }, { 'line1' })
      vim.api.nvim_set_current_buf(buf_id)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })

      -- Trigger text object
      diff.textobject()

      -- Check visual selection (simplified check)
      local mode = vim.fn.mode()
      assert.is_true(mode == 'v' or mode == 'V')
      local start_line = vim.fn.line('v')
      local end_line = vim.fn.line('.')
      assert.are.same(2, start_line)
      assert.are.same(2, end_line)
    end)
  end)
end)
