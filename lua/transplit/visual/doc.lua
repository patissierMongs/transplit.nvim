-- Pure transformations of a visualization document (Markdown with ```d2 / ```mermaid blocks).
local M = {}

---Some models wrap the whole document in a ```markdown fence.
function M.clean(text)
  text = vim.trim(text)
  text = text:match("^```m[a-z]*\n(.*)\n```$") or text
  -- a fix response sometimes starts with an explanation before the document itself
  if not text:match("^# ") then
    local start = text:find("\n# ")
    if start then
      text = text:sub(start + 1)
    end
  end
  return text
end

---@class transplit.Block
---@field lang string
---@field first integer line of the opening fence (1-based)
---@field last integer line of the closing fence
---@field code string[]
---@field index? integer position among blocks of the same language (d2)
---@field svg_path? string
---@field ascii? string[]
---@field err? string compile error
---@field warn? string rule violation worth an automatic fix

---Fenced code blocks; an unterminated block is ignored.
---@return transplit.Block[]
function M.parse_blocks(markdown)
  local blocks, cur = {}, nil
  for i, line in ipairs(vim.split(markdown, "\n")) do
    if cur then
      if line:match("^```%s*$") then
        cur.last = i
        blocks[#blocks + 1] = cur
        cur = nil
      else
        cur.code[#cur.code + 1] = line
      end
    else
      local lang = line:match("^```%s*([%w_%-]+)%s*$")
      if lang then
        cur = { lang = lang:lower(), first = i, code = {} }
      end
    end
  end
  return blocks
end

---First D2 line (outside comments) with non-ASCII text: double-width characters break
---the terminal rendering, so labels must stay ASCII.
---@return integer?, string?
function M.non_ascii_line(code)
  for n, line in ipairs(code) do
    if not line:match("^%s*#") and line:find("[\128-\255]") then
      return n, vim.trim(line):sub(1, 80)
    end
  end
end

---Walk the document, replacing each block through `on_block` (which returns lines).
local function transform(markdown, blocks, on_block, on_line)
  local lines = vim.split(markdown, "\n")
  local by_first = {}
  for _, b in ipairs(blocks) do
    by_first[b.first] = b
  end
  local out, i = {}, 1
  while i <= #lines do
    local b = by_first[i]
    if b then
      vim.list_extend(out, on_block(b, lines))
      i = b.last + 1
    else
      out[#out + 1] = on_line and on_line(lines[i]) or lines[i]
      i = i + 1
    end
  end
  return out
end

---The nvim view: D2 blocks replaced by their text rendering.
---@param msg fun(key: string): string
function M.to_view(markdown, blocks, msg)
  return transform(markdown, blocks, function(b, lines)
    if b.lang == "d2" and b.err then
      return vim.list_extend(
        vim.list_extend({ "> ⚠ " .. msg("d2_error") .. ": " .. b.err, "```d2" }, b.code),
        { "```" }
      )
    elseif b.lang == "d2" and b.ascii then
      return vim.list_extend(vim.list_extend({ "```text" }, b.ascii), { "```" })
    elseif b.lang == "d2" then
      return { "> " .. msg("no_text_render") }
    elseif b.lang == "mermaid" then
      return vim.list_extend(vim.list_extend({ "> " .. msg("mermaid_in_browser"), "```mermaid" }, b.code), { "```" })
    end
    return vim.list_slice(lines, b.first, b.last)
  end)
end

local function org_inline(s)
  s = s:gsub("%*%*(.-)%*%*", "*%1*")
  s = s:gsub("`([^`]+)`", "~%1~")
  return s
end

---Org version for Emacs, with compiled D2 blocks as inline SVG images.
---@param msg fun(key: string): string
function M.to_org(markdown, blocks, title, msg)
  local body = transform(markdown, blocks, function(b)
    if b.lang == "d2" and not b.err then
      return { "[[file:" .. b.svg_path .. "]]" }
    elseif b.lang == "mermaid" then
      return { "/" .. msg("mermaid_org") .. "/" }
    end
    return vim.list_extend(vim.list_extend({ "#+begin_src " .. b.lang }, b.code), { "#+end_src" })
  end, function(l)
    local hashes, text = l:match("^(#+)%s+(.*)$")
    if hashes then
      return ("*"):rep(#hashes) .. " " .. org_inline(text)
    elseif l:match("^%s*|[%s:|%-]+|%s*$") and l:find("%-%-") then
      return "|-" -- Org realigns the table when the file is opened
    end
    -- "* item" would become an Org headline
    return org_inline((l:gsub("^(%s*)%* ", "%1- "):gsub("^>%s?", "")))
  end)
  return vim.list_extend({ "#+title: " .. title, "" }, body)
end

---Quote a string for an Emacs Lisp form.
function M.elisp_str(s)
  return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"'
end

return M
