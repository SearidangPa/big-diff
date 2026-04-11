local H = require('big-diff.utils_log')
local M = {}

local is_supported_utf8_encoding = function(fileencoding)
  local encoding = string.lower(fileencoding or '')
  return encoding == '' or encoding == 'utf-8' or encoding == 'utf8'
end

local is_string_utf8 = function(text)
  local ok, converted = pcall(vim.fn.iconv, text, 'utf-8', 'utf-8')
  if not ok or converted ~= text then return false end

  local ok_index, char_count = pcall(vim.str_utfindex, text)
  if not ok_index then return false end

  local ok_byteindex, byte_index = pcall(vim.str_byteindex, text, char_count)
  return ok_byteindex and byte_index == #text
end

-- BOM bytes prepended to buffer text if 'bomb' is enabled. See `:h bom-bytes`.
--stylua: ignore
M.bom_bytes = {
  ['utf-8']    = string.char(0xef, 0xbb, 0xbf),
  ['utf-16be'] = string.char(0xfe, 0xff),
  ['utf-16']   = string.char(0xfe, 0xff),
  ['utf-16le'] = string.char(0xff, 0xfe),
  -- In 'fileencoding', 'utf-32' is transformed into 'ucs-4'
  ['utf-32be'] = string.char(0x00, 0x00, 0xfe, 0xff),
  ['ucs-4be']  = string.char(0x00, 0x00, 0xfe, 0xff),
  ['utf-32']   = string.char(0x00, 0x00, 0xfe, 0xff),
  ['ucs-4']    = string.char(0x00, 0x00, 0xfe, 0xff),
  ['utf-32le'] = string.char(0xff, 0xfe, 0x00, 0x00),
  ['ucs-4le']  = string.char(0xff, 0xfe, 0x00, 0x00),
}

M.buf_ensure_loaded = function(buf_id)
  if type(buf_id) ~= 'number' or vim.api.nvim_buf_is_loaded(buf_id) then return end
  local cache_eventignore = vim.o.eventignore
  vim.o.eventignore = 'BufEnter,BufWinEnter'
  pcall(vim.fn.bufload, buf_id)
  vim.o.eventignore = cache_eventignore
end

M.map = function(mode, lhs, rhs, opts)
  if lhs == '' then return end
  opts = vim.tbl_deep_extend('force', { silent = true }, opts or {})
  vim.keymap.set(mode, lhs, rhs, opts)
end

M.set_extmark = function(...) pcall(vim.api.nvim_buf_set_extmark, ...) end

M.get_extmarks = function(...)
  local ok, res = pcall(vim.api.nvim_buf_get_extmarks, ...)
  if not ok then return {} end
  return res
end

M.clear_namespace = function(...) pcall(vim.api.nvim_buf_clear_namespace, ...) end

-- Cache for is_buf_text results per buffer (avoids reading bytes on every BufEnter)
local buf_is_text_cache = {}

M.is_buf_text = function(buf_id)
  if buf_is_text_cache[buf_id] ~= nil then
    return buf_is_text_cache[buf_id]
  end
  local n = vim.api.nvim_buf_call(buf_id, function() return vim.fn.byte2line(1024) end)
  local lines = vim.api.nvim_buf_get_lines(buf_id, 0, n, false)
  local result = table.concat(lines, ''):find('\0') == nil
  buf_is_text_cache[buf_id] = result
  return result
end

M.is_buf_utf8 = function(buf_id)
  return is_supported_utf8_encoding(vim.bo[buf_id].fileencoding)
end

M.is_buf_text_utf8 = function(buf_id)
  return M.is_buf_text(buf_id) and M.is_buf_utf8(buf_id)
end

M.assert_buf_text_utf8 = function(buf_id)
  if not M.is_buf_text(buf_id) then
    H.error(string.format('Buffer %d is not a text buffer. big-diff only supports UTF-8 text buffers.', buf_id))
  end

  local fileencoding = vim.bo[buf_id].fileencoding
  if M.is_buf_utf8(buf_id) then return end

  H.error(string.format(
    'Buffer %d uses unsupported fileencoding %s. big-diff only supports UTF-8 text buffers.',
    buf_id,
    vim.inspect(fileencoding)
  ))
end

M.is_text_utf8 = function(text)
  if type(text) ~= 'string' then return false end
  if not is_string_utf8(text) then return false end

  for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
    if not is_string_utf8(line) then return false end
  end

  return true
end

M.assert_text_utf8 = function(text, name)
  if M.is_text_utf8(text) then return end
  H.error(string.format('%s must be valid UTF-8 text.', name or 'Text'))
end

-- Invalidate is_buf_text cache for a buffer (call on buffer reload)
M.invalidate_buf_text_cache = function(buf_id)
  buf_is_text_cache[buf_id] = nil
end

M.get_buftext = function(buf_id)
  M.assert_buf_text_utf8(buf_id)

  local lines = vim.api.nvim_buf_get_lines(buf_id, 0, -1, false)
  -- - NOTE: Appending '\n' makes more intuitive diffs at end-of-file
  local text = table.concat(lines, '\n') .. '\n'
  if not vim.bo[buf_id].bomb then return text, lines end
  local bytes = M.bom_bytes[vim.bo[buf_id].fileencoding] or ''
  lines[1] = bytes .. lines[1]
  return bytes .. text, lines
end

-- Try getting buffer's full real path (after resolving symlinks)
M.get_buf_realpath = function(buf_id) return vim.loop.fs_realpath(vim.api.nvim_buf_get_name(buf_id)) or '' end

-- nvim__redraw replaced nvim__buf_redraw_range during the 0.10 release cycle
M.redraw_buffer = function(buf_id)
  vim.api.nvim__buf_redraw_range(buf_id, 0, -1)

  -- Redraw statusline to have possible statusline component up to date
  vim.cmd('redrawstatus')
end
if vim.api.nvim__redraw ~= nil then
  M.redraw_buffer = function(buf_id) vim.api.nvim__redraw({ buf = buf_id, valid = true, statusline = true }) end
end

return M
