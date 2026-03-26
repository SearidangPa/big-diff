local diff = require('mini.diff')
local helpers = require('tests.helpers')

describe('mini.diff API', function()
  local get_local_nmap = function(buf_id, lhs)
    return vim.api.nvim_buf_call(buf_id, function()
      local map = vim.fn.maparg(lhs, 'n', false, true)
      if type(map) ~= 'table' or vim.tbl_isempty(map) or map.buffer ~= 1 then return nil end
      return map
    end)
  end

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

    it('installs and removes local paging workaround maps on odd/even toggles', function()
      local buf_id = helpers.setup_buffer({ 'a', 'b' }, { 'a' })

      assert.is_nil(get_local_nmap(buf_id, '<C-d>'))
      assert.is_nil(get_local_nmap(buf_id, '<C-u>'))

      diff.toggle_overlay()
      assert.is_not_nil(get_local_nmap(buf_id, '<C-d>'))
      assert.is_not_nil(get_local_nmap(buf_id, '<C-u>'))

      diff.toggle_overlay()
      assert.is_nil(get_local_nmap(buf_id, '<C-d>'))
      assert.is_nil(get_local_nmap(buf_id, '<C-u>'))

      diff.toggle_overlay()
      assert.is_not_nil(get_local_nmap(buf_id, '<C-d>'))
      assert.is_not_nil(get_local_nmap(buf_id, '<C-u>'))

      diff.toggle_overlay()
      assert.is_nil(get_local_nmap(buf_id, '<C-d>'))
      assert.is_nil(get_local_nmap(buf_id, '<C-u>'))
    end)

    it('restores existing local Ctrl-D and Ctrl-U mappings after toggle off', function()
      local buf_id = helpers.setup_buffer({ 'a', 'b' }, { 'a' })

      vim.keymap.set('n', '<C-d>', '<Cmd>echo "local-down"<CR>', { buffer = buf_id, silent = true })
      vim.keymap.set('n', '<C-u>', '<Cmd>echo "local-up"<CR>', { buffer = buf_id, silent = true })

      local before_down = get_local_nmap(buf_id, '<C-d>')
      local before_up = get_local_nmap(buf_id, '<C-u>')

      diff.toggle_overlay()
      local during_down = get_local_nmap(buf_id, '<C-d>')
      local during_up = get_local_nmap(buf_id, '<C-u>')
      assert.is_not_nil(during_down.callback)
      assert.is_not_nil(during_up.callback)

      diff.toggle_overlay()
      local after_down = get_local_nmap(buf_id, '<C-d>')
      local after_up = get_local_nmap(buf_id, '<C-u>')
      assert.are.same(before_down.rhs, after_down.rhs)
      assert.are.same(before_up.rhs, after_up.rhs)
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
       
       -- Check summary content (simplified to hunk navigation summary)
       assert.are.same('none', data.summary.source_name)
       assert.are.same(1, data.summary.hunk_total)
       assert.is_nil(data.summary.hunk_idx)
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
