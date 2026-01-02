local M = {}

M.str_utfindex = function(s, i) return vim.str_utfindex(s, 'utf-32', i) end
if vim.fn.has('nvim-0.11') == 0 then M.str_utfindex = function(s, i) return (vim.str_utfindex(s, i)) end end

M.slice_line = function(line)
  -- Intertwine every proper character with '\n'
  local line_len = line:len()
  local sliced, starts, ends
  -- Make short route for a very common case of no multibyte characters
  if M.str_utfindex(line) == line_len then
    sliced, starts, ends = line:gsub('(.)', '%1\n'), {}, {}
    for i = 1, string.len(line) do
      starts[i], ends[i] = i, i
    end
  else
    sliced, starts, ends = {}, vim.str_utf_pos(line), {}
    for i = 1, #starts - 1 do
      table.insert(sliced, line:sub(starts[i], starts[i + 1] - 1))
      table.insert(ends, starts[i + 1] - 1)
    end
    table.insert(sliced, line:sub(starts[#starts], line_len))
    table.insert(ends, line_len)
    sliced = table.concat(sliced, '\n') .. '\n'
  end

  return sliced, starts, ends
end

return M
