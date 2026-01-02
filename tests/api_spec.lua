local diff = require('mini.diff')
local helpers = require('tests.helpers')

describe('mini.diff API', function()
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

  describe('buffer management', function()
    it('enable/disable/toggle works', function()
      -- Use helpers.setup_buffer which sets up a buffer with 'none' source.
      local buf_id = helpers.setup_buffer({ 'a' }, { 'a' })
      assert.is_not_nil(diff.get_buf_data(buf_id))

      diff.disable(buf_id)
      assert.is_nil(diff.get_buf_data(buf_id))

      diff.enable(buf_id)
      assert.is_not_nil(diff.get_buf_data(buf_id))

      diff.toggle(buf_id)
      assert.is_nil(diff.get_buf_data(buf_id))
      
      diff.toggle(buf_id)
      assert.is_not_nil(diff.get_buf_data(buf_id))
    end)
  end)

  describe('overlay', function()
    it('toggles overlay', function()
      local buf_id = helpers.setup_buffer({ 'a' }, { 'a' })
      local data = diff.get_buf_data(buf_id)
      assert.is_false(data.overlay)

      diff.toggle_overlay(buf_id)
      data = diff.get_buf_data(buf_id)
      assert.is_true(data.overlay)

      diff.toggle_overlay(buf_id)
      data = diff.get_buf_data(buf_id)
      assert.is_false(data.overlay)
    end)
  end)

  describe('data retrieval', function()
    it('get_buf_data returns correct structure', function()
       local buf_id = helpers.setup_buffer({ 'line1' }, { 'line1', 'line2' })
       local data = diff.get_buf_data(buf_id)
       
       assert.is_table(data)
       assert.is_table(data.config)
       assert.is_table(data.hunks)
       assert.is_boolean(data.overlay)
       assert.is_string(data.ref_text)
       assert.is_table(data.summary)
       
       -- Check summary content
       -- Deleted 1 line (line2)
       assert.are.same(1, data.summary.delete)
    end)
  end)

  describe('reference text', function()
    it('set_ref_text updates diff', function()
      local buf_id = helpers.setup_buffer({ 'a' }, { 'a' })
      helpers.expect_hunks(buf_id, {})

      diff.set_ref_text(buf_id, { 'a', 'b' })
      helpers.wait_for_update(buf_id)
      
      helpers.expect_hunks(buf_id, {
        { type = 'delete', buf_start = 1, buf_count = 0, ref_start = 2, ref_count = 1 }
      })
      
      local data = diff.get_buf_data(buf_id)
      assert.are.same('a\nb\n', data.ref_text)
    end)
  end)
  
  describe('export', function()
     it('exports to qf', function()
        local buf_id = helpers.setup_buffer({ 'line1', 'new' }, { 'line1' })
        vim.api.nvim_set_current_buf(buf_id)
        
        -- Export to quickfix
        -- export returns the list, it doesn't set it (unless maybe that's what H.hunk.export does? No, it returns res)
        -- wait, I need to check if export sets qflist or just returns items.
        -- Reading H.hunk.export again:
        -- "return res"
        
        local items = diff.export('qf')
        assert.are.same(1, #items)
        assert.are.same('Add', items[1].text)
        assert.are.same(2, items[1].lnum)
        
        -- Also check with scope='all' (default) vs 'current'
     end)
  end)

end)
