local H = {
  vim = require('mini.diff.utils_vim'),
  state = require('mini.diff.state'),
}

local M = {}
M.gen_source = {}

-- Git helpers ----------------------------------------------------------------
local git_read_stream = function(stream, feed)
  local callback = function(err, data)
    if data ~= nil then return table.insert(feed, data) end
    if err then feed[1] = nil end
    stream:close()
  end
  stream:read_start(callback)
end

local git_invalidate_cache = function(cache)
  if cache == nil then return end
  pcall(vim.loop.fs_event_stop, cache.fs_event)
  pcall(vim.loop.timer_stop, cache.timer)
end

local git_set_ref_text = vim.schedule_wrap(function(buf_id)
  if not vim.api.nvim_buf_is_valid(buf_id) then return end
  local buf_set_ref_text = vim.schedule_wrap(function(text) pcall(_G.MiniDiff.set_ref_text, buf_id, text) end)

  -- NOTE: Do not cache buffer's name to react to its possible rename
  local path = H.vim.get_buf_realpath(buf_id)
  if path == '' then return buf_set_ref_text({}) end
  local cwd, basename = vim.fn.fnamemodify(path, ':h'), vim.fn.fnamemodify(path, ':t')

  -- Set
  local stdout = vim.loop.new_pipe()
  local spawn_opts = { args = { 'show', ':0:./' .. basename }, cwd = cwd, stdio = { nil, stdout, nil } }

  local process, stdout_feed = nil, {}
  local on_exit = function(exit_code)
    process:close()

    -- Unset reference text in case of any error. This results into not showing
    -- hunks at all. Possible reasons to do so:
    -- - 'Not in index' files (new, ignored, etc.).
    -- - 'Neither in index nor on disk' files (after checking out commit which
    --   does not yet have file created).
    -- - 'Relative can not be used outside working tree' (when opening file
    --   inside '.git' directory).
    if exit_code ~= 0 or stdout_feed[1] == nil then return buf_set_ref_text({}) end

    -- Set reference text accounting for possible 'crlf' end of line in index
    local text = table.concat(stdout_feed, ''):gsub('\r\n', '\n')
    buf_set_ref_text(text)
  end

  process = vim.loop.spawn('git', spawn_opts, on_exit)
  git_read_stream(stdout, stdout_feed)
end)

local git_setup_index_watch = function(buf_id, git_dir_path)
  local buf_fs_event, timer = vim.loop.new_fs_event(), vim.loop.new_timer()
  local buf_git_set_ref_text = function() git_set_ref_text(buf_id) end

  local watch_index = function(_, filename, _)
    if filename ~= 'index' then return end
    -- Debounce to not overload during incremental staging (like in script)
    timer:stop()
    timer:start(50, 0, buf_git_set_ref_text)
  end
  buf_fs_event:start(git_dir_path, { recursive = false }, watch_index)

  git_invalidate_cache(H.state.git_cache[buf_id])
  H.state.git_cache[buf_id] = { fs_event = buf_fs_event, timer = timer }
end

local git_start_watching_index = function(buf_id, path)
  -- NOTE: Watching single 'index' file is not enough as staging by Git is done
  -- via "create fresh 'index.lock' file, apply modifications, change file name
  -- to 'index'". Hence watch the whole '.git' (first level) and react only if
  -- change was in 'index' file.
  local stdout = vim.loop.new_pipe()
  local args = { 'rev-parse', '--path-format=absolute', '--git-dir' }
  local spawn_opts = { args = args, cwd = vim.fn.fnamemodify(path, ':h'), stdio = { nil, stdout, nil } }

  -- If path is not in Git, disable buffer but make sure that it will not try
  -- to re-attach until buffer is properly disabled
  local on_not_in_git = vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(buf_id) then
      H.state.cache[buf_id] = nil
      return
    end
    _G.MiniDiff.fail_attach(buf_id)
    H.state.git_cache[buf_id] = {}
  end)

  local process, stdout_feed = nil, {}
  local on_exit = function(exit_code)
    process:close()

    -- Watch index only if there was no error retrieving path to it
    if exit_code ~= 0 or stdout_feed[1] == nil then return on_not_in_git() end

    -- Set up index watching
    local git_dir_path = table.concat(stdout_feed, ''):gsub('\n+$', '')
    git_setup_index_watch(buf_id, git_dir_path)

    -- Set reference text immediately
    git_set_ref_text(buf_id)
  end

  process = vim.loop.spawn('git', spawn_opts, on_exit)
  git_read_stream(stdout, stdout_feed)
end

local git_get_path_data = function(path)
  -- Get path data needed for proper patch header
  local cwd, basename = vim.fn.fnamemodify(path, ':h'), vim.fn.fnamemodify(path, ':t')
  local stdout = vim.loop.new_pipe()
  local args = { 'ls-files', '-z', '--full-name', '--format=%(objectmode) %(eolinfo:index) %(path)', '--', basename }
  local spawn_opts = { args = args, cwd = cwd, stdio = { nil, stdout, nil } }

  local process, stdout_feed, res, did_exit = nil, {}, { cwd = cwd }, false
  local on_exit = function(exit_code)
    process:close()

    did_exit = true
    if exit_code ~= 0 then return end
    -- Parse data about path
    local out = table.concat(stdout_feed, ''):gsub('(%z\n)+$', '')
    res.mode_bits, res.eol, res.rel_path = string.match(out, '^(%d+) (%S+) (.*)$')
  end

  process = vim.loop.spawn('git', spawn_opts, on_exit)
  git_read_stream(stdout, stdout_feed)
  vim.wait(1000, function() return did_exit end, 1)
  return res
end

local git_format_patch = function(buf_id, hunks, path_data)
  local _, buf_lines = H.vim.get_buftext(buf_id)
  local ref_lines = vim.split(H.state.cache[buf_id].ref_text, '\n')

  local res = {
    string.format('diff --git a/%s b/%s', path_data.rel_path, path_data.rel_path),
    'index 000000..000000 ' .. path_data.mode_bits,
    '--- a/' .. path_data.rel_path,
    '+++ b/' .. path_data.rel_path,
  }

  -- Take into account changing target ref region as a result of previous hunks
  local offset = 0
  local cr_eol = path_data.eol == 'crlf' and '\r' or ''
  for _, h in ipairs(hunks) do
    -- "Add" hunks have reference line above target
    local start = h.ref_start + (h.ref_count == 0 and 1 or 0)

    table.insert(res, string.format('@@ -%d,%d +%d,%d @@', start, h.ref_count, start + offset, h.buf_count))
    for i = h.ref_start, h.ref_start + h.ref_count - 1 do
      table.insert(res, '-' .. ref_lines[i] .. cr_eol)
    end
    for i = h.buf_start, h.buf_start + h.buf_count - 1 do
      table.insert(res, '+' .. buf_lines[i] .. cr_eol)
    end
    offset = offset + (h.buf_count - h.ref_count)
  end

  return res
end

local git_apply_patch = function(path_data, patch)
  local stdin = vim.loop.new_pipe()
  local args = { 'apply', '--whitespace=nowarn', '--cached', '--unidiff-zero', '-' }
  local spawn_opts = { args = args, cwd = path_data.cwd, stdio = { stdin, nil, nil } }
  local process
  process = vim.loop.spawn('git', spawn_opts, function() process:close() end)

  -- Write patch, notify that writing is finished (shutdown), and close
  for _, l in ipairs(patch) do
    stdin:write(l)
    stdin:write('\n')
  end
  stdin:shutdown(function() stdin:close() end)
end

-- Sources --------------------------------------------------------------------
M.gen_source.git = function()
  local attach = function(buf_id)
    -- Try attaching to a buffer only once
    if H.state.git_cache[buf_id] ~= nil then return false end
    -- - Possibly resolve symlinks to get data from the original repo
    local path = H.vim.get_buf_realpath(buf_id)
    if path == '' then return false end

    H.state.git_cache[buf_id] = {}
    git_start_watching_index(buf_id, path)
  end

  local detach = function(buf_id)
    local cache = H.state.git_cache[buf_id]
    H.state.git_cache[buf_id] = nil
    git_invalidate_cache(cache)
  end

  local apply_hunks = function(buf_id, hunks)
    local path_data = git_get_path_data(H.vim.get_buf_realpath(buf_id))
    if path_data == nil or path_data.rel_path == nil then return end
    local patch = git_format_patch(buf_id, hunks, path_data)
    git_apply_patch(path_data, patch)
  end

  return { name = 'git', attach = attach, detach = detach, apply_hunks = apply_hunks }
end

M.gen_source.none = function()
  return { name = 'none', attach = function() end }
end

M.gen_source.save = function()
  local augroups = {}
  local attach = function(buf_id)
    local augroup = vim.api.nvim_create_augroup('MiniDiffSourceSaveBuffer' .. buf_id, { clear = true })
    augroups[buf_id] = augroup

    local set_ref = function()
      if vim.bo[buf_id].modified then return end
      _G.MiniDiff.set_ref_text(buf_id, H.vim.get_buftext(buf_id))
    end

    -- Autocommand are more efficient than file watcher as it doesn't read disk
    local au_opts = { group = augroup, buffer = buf_id, callback = set_ref, desc = 'Set reference text after save' }
    vim.api.nvim_create_autocmd({ 'BufWritePost', 'FileChangedShellPost' }, au_opts)
    set_ref()
  end

  local detach = function(buf_id) pcall(vim.api.nvim_del_augroup_by_id, augroups[buf_id]) end

  return { name = 'save', attach = attach, detach = detach }
end

return M
