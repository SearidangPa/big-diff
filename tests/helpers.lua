local M = {}

M.setup_buffer = function(lines, ref_lines)
  local buf_id = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_lines(buf_id, 0, -1, false, lines)
  
  -- Set reference text manually to avoid git dependency in tests
  -- Use 'none' source to avoid git attachment failure on scratch buffer
  vim.b[buf_id].minidiff_config = { source = require('mini.diff').gen_source.none() }

  require("mini.diff").set_ref_text(buf_id, ref_lines)
  
  M.wait_for_update(buf_id)
  
  return buf_id
end

M.wait_for_update = function(buf_id)
  local done = false
  local id = vim.api.nvim_create_autocmd('User', {
    pattern = 'MiniDiffUpdated',
    callback = function()
      if vim.api.nvim_get_current_buf() == buf_id then done = true end
    end,
  })
  vim.wait(1000, function() return done end)
  pcall(vim.api.nvim_del_autocmd, id)
end

M.get_hunks = function(buf_id)
  return require("mini.diff").get_buf_data(buf_id).hunks
end

M.expect_hunks = function(buf_id, expected)
  local hunks = M.get_hunks(buf_id)
  
  assert.are.same(#expected, #hunks, "Hunk count mismatch")
  
  for i, exp in ipairs(expected) do
    local got = hunks[i]
    assert.are.same(exp.type, got.type, "Hunk type mismatch at index " .. i)
    assert.are.same(exp.buf_start, got.buf_start, "Hunk buf_start mismatch at index " .. i)
    assert.are.same(exp.buf_count, got.buf_count, "Hunk buf_count mismatch at index " .. i)
    assert.are.same(exp.ref_start, got.ref_start, "Hunk ref_start mismatch at index " .. i)
    assert.are.same(exp.ref_count, got.ref_count, "Hunk ref_count mismatch at index " .. i)
  end
end

M.mock_source = function()
  local applied_hunks = {}
  return {
    name = "mock",
    attach = function() return true end,
    detach = function() end,
    apply_hunks = function(buf_id, hunks)
      applied_hunks = hunks
    end,
    get_applied_hunks = function() return applied_hunks end
  }
end

return M
