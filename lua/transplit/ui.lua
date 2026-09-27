-- Window helpers shared by translation, explanation and visualization.
local M = {}

---Translation sessions keyed by source buffer (owned by transplit.translate).
---@type table<integer, table>
M.sessions = {}

---The buffer the user means: the source buffer when called from a translation pane.
function M.source_buf()
  local buf = vim.api.nvim_get_current_buf()
  for sbuf, sess in pairs(M.sessions) do
    if sess.tbuf == buf then
      return sbuf
    end
  end
  return buf
end

---winbar is a statusline format string: a literal % must be doubled.
function M.set_winbar(win, text)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_option_value("winbar", " " .. text:gsub("%%", "%%%%"), { win = win })
  end
end

local side_win

---Show buf in a right-hand window shared by explanations and visualizations.
function M.side_window(buf)
  if not (side_win and vim.api.nvim_win_is_valid(side_win)) then
    local cur = vim.api.nvim_get_current_win()
    vim.cmd("botright vsplit")
    side_win = vim.api.nvim_get_current_win()
    vim.api.nvim_set_current_win(cur)
  end
  vim.api.nvim_win_set_buf(side_win, buf)
  -- a split of a translation window inherits scroll/cursor binding
  vim.wo[side_win].scrollbind = false
  vim.wo[side_win].cursorbind = false
  vim.wo[side_win].wrap = true
  vim.wo[side_win].linebreak = true
  vim.wo[side_win].number = false
  return side_win
end

---Replace the lines of a buffer that is kept non-modifiable.
function M.set_lines(buf, first, last, lines)
  if vim.api.nvim_buf_is_valid(buf) then
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, first, last, false, lines)
    vim.bo[buf].modifiable = false
  end
end

return M
