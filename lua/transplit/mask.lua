-- Value masking for translation.
--
-- Log lines mostly differ only in timestamps, IPs, numbers, paths and quoted strings.
-- Those are replaced by placeholders (⟪a⟫, ⟪b⟫, ...) so that only the unique *templates*
-- are sent to the LLM, and the original values are put back verbatim afterwards: the
-- model can't alter them, and one translation covers every line with the same shape.
local M = {}

M.OPEN, M.CLOSE = "⟪", "⟫"
local OPEN, CLOSE = M.OPEN, M.CLOSE
local TOKEN = OPEN .. "%l+" .. CLOSE

-- Order matters: earlier patterns win, later ones skip text already masked.
M.patterns = {
  '"[^"]*"', -- quoted strings: request lines, user agents, paths
  "%[%d+/%a+/%d+:[^%]]*%]", -- access log time [18/Sep/2026:10:12:01 +0900]
  "%[[^%]%s]*%]", -- [error], [notice], [12345]
  "%d%d%d%d[/%-]%d%d[/%-]%d%d[T ]%d%d:%d%d:%d%d[%.%d]*[Z%+%-%d:]*", -- timestamps
  "%a[%w+.-]*://[^%s,;\"']+", -- URLs
  "%d+%.%d+%.%d+%.%d+[:%d]*", -- IPv4[:port]
  "[%w%-]+%.[%w%-%.]*[%w%-]+%.%a%a+", -- host names (a.b.com)
  "/[^%s,;\"']*", -- paths
  "[%w_%-%.#*]*%d[%w_%-%.#*:]*", -- anything with digits: 812#812: *3 10485760 v1.2
}

---Placeholder for the i-th value: a..z, aa, ab, ...
function M.token(i)
  local s = ""
  repeat
    local r = (i - 1) % 26
    s = string.char(97 + r) .. s
    i = (i - 1 - r) / 26
  until i == 0
  return OPEN .. s .. CLOSE
end

---@param line string
---@return string template, string[] values
function M.mask(line)
  local vals = {}
  local t = line
  for _, pat in ipairs(M.patterns) do
    t = t:gsub(pat, function(m)
      if m:find(OPEN, 1, true) then
        return m -- overlaps an earlier placeholder; leave as-is
      end
      vals[#vals + 1] = m
      return M.token(#vals)
    end)
  end
  return t, vals
end

---@param tmpl string
---@param vals string[]
function M.unmask(tmpl, vals)
  return (
    tmpl:gsub(OPEN .. "(%l+)" .. CLOSE, function(s)
      local i = 0
      for c in s:gmatch(".") do
        i = i * 26 + (c:byte() - 96)
      end
      return vals[i] or (OPEN .. s .. CLOSE)
    end)
  )
end

---Nothing left to translate once placeholders are removed.
function M.is_trivial(tmpl)
  local rest = tmpl:gsub(TOKEN, "")
  return not rest:find("%a%a")
end

---A translation is usable only if it kept exactly the same placeholders.
function M.valid(src, dst)
  if type(dst) ~= "string" then
    return false
  end
  local a, b = {}, {}
  for t in src:gmatch(TOKEN) do
    a[#a + 1] = t
  end
  for t in dst:gmatch(TOKEN) do
    b[#b + 1] = t
  end
  table.sort(a)
  table.sort(b)
  return vim.deep_equal(a, b)
end

---Split off leading/trailing whitespace, which is re-attached locally rather than
---trusted to the model: man pages, YAML and code depend on exact indentation.
---@return string lead, string body, string trail
function M.split_ws(line)
  return line:match("^(%s*)(.-)(%s*)$")
end

return M
