-- Context sent to the LLM, cheapest first:
--   * file path/name/filetype/size/line count, plus the relevant lines
--   * a per-file "profile" (what this file is, its format, glossary): produced as a side
--     output of the first translation from the head/tail lines and a bounded directory
--     tree, then reused instead of resending that raw context
--   * for whole-file work: the file (or head/tail + recurring line patterns when large),
--     the directory tree and files it references by relative path (never secrets)
local cache = require("transplit.cache")
local config = require("transplit.config")
local mask = require("transplit.mask")

local M = {}

local function opts()
  return config.options
end

function M.human(n)
  if not n or n < 0 then
    return "?"
  end
  for _, u in ipairs({ "B", "K", "M", "G" }) do
    if n < 1024 then
      return (u == "B" and "%d%s" or "%.1f%s"):format(n, u)
    end
    n = n / 1024
  end
  return ("%.1fT"):format(n)
end

local tree_skip = { [".git"] = true, node_modules = true, __pycache__ = true, [".venv"] = true, target = true }

---Bounded directory listing with sizes (names only, never file contents).
function M.tree(root)
  local out, count = { root .. "/" }, 0
  local function walk(dir, depth, indent)
    local entries = {}
    for name, typ in vim.fs.dir(dir) do
      entries[#entries + 1] = { name, typ }
      if #entries > 2000 then
        break
      end
    end
    table.sort(entries, function(a, b)
      return a[1] < b[1]
    end)
    for _, e in ipairs(entries) do
      if count >= opts().tree_max then
        out[#out + 1] = indent .. "… (truncated)"
        return false
      end
      count = count + 1
      local path = dir .. "/" .. e[1]
      if e[2] == "directory" then
        out[#out + 1] = indent .. e[1] .. "/"
        if not tree_skip[e[1]] and depth < opts().tree_depth then
          if walk(path, depth + 1, indent .. "  ") == false then
            return false
          end
        end
      else
        out[#out + 1] = indent .. e[1] .. " (" .. M.human(vim.fn.getfsize(path)) .. ")"
      end
    end
  end
  pcall(walk, root, 1, "  ")
  return table.concat(out, "\n")
end

---Lines [first, last] prefixed with their numbers; lines inside `mark` get ">>".
---@param mark? integer[] {first, last}
function M.numbered(buf, first, last, mark)
  local lines = vim.api.nvim_buf_get_lines(buf, first - 1, last, false)
  for i, l in ipairs(lines) do
    local n = first + i - 1
    local prefix = (mark and n >= mark[1] and n <= mark[2]) and ">>" or "  "
    lines[i] = ("%s%5d| %s"):format(prefix, n, #l > 400 and l:sub(1, 400) .. "…" or l)
  end
  return table.concat(lines, "\n")
end

---Stable identity of a buffer for caching.
function M.file_key(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  if name ~= "" then
    return vim.fn.fnamemodify(name, ":p")
  end
  -- piped output (`cmd | nvim -`) has no name: key it by content so unrelated outputs
  -- don't share a profile, and the same command's output reuses its cache next time
  local head = table.concat(vim.api.nvim_buf_get_lines(buf, 0, 20, false), "\n")
  return "[stdin " .. vim.fn.sha256(head):sub(1, 12) .. "]"
end

---A real file on disk (not man://, a stdin pipe, a terminal, ...).
function M.on_disk(buf)
  return vim.bo[buf].buftype == "" and vim.fn.filereadable(M.file_key(buf)) == 1
end

function M.file_info(buf)
  local key = M.file_key(buf)
  local ft = vim.bo[buf].filetype ~= "" and vim.bo[buf].filetype or "unknown"
  local lines = vim.api.nvim_buf_line_count(buf)
  if not M.on_disk(buf) then
    local info = {
      "source: " .. (key:match("^%[stdin") and "unnamed buffer (e.g. command output piped into the editor)" or key),
      "filetype: " .. ft,
      "lines: " .. lines,
    }
    if ft ~= "man" then
      info[#info + 1] = "cwd: " .. vim.fn.getcwd()
    end
    return table.concat(info, "\n")
  end
  return table.concat({
    "path: " .. key,
    "filename: " .. vim.fn.fnamemodify(key, ":t"),
    "filetype: " .. ft,
    "size: " .. M.human(vim.fn.getfsize(key)) .. ", lines: " .. lines,
    "cwd: " .. vim.fn.getcwd(),
  }, "\n")
end

---Directory trees of the file's directory and cwd.
function M.trees(buf)
  -- a man page or help text has nothing to do with the directory it was opened from
  local dirs = vim.bo[buf].filetype ~= "man" and { vim.fn.getcwd() } or {}
  if M.on_disk(buf) then
    local fdir = vim.fn.fnamemodify(M.file_key(buf), ":h")
    if fdir ~= dirs[1] then
      table.insert(dirs, 1, fdir)
    end
  end
  local parts = {}
  for _, d in ipairs(dirs) do
    parts[#parts + 1] = "<directory_tree>\n" .. M.tree(d) .. "\n</directory_tree>"
  end
  return table.concat(parts, "\n")
end

---Raw orientation context: head/tail of the file and directory trees.
function M.raw_context(buf)
  local n = vim.api.nvim_buf_line_count(buf)
  local head, tail = opts().head, opts().tail
  local parts = { "<file_head>\n" .. M.numbered(buf, 1, math.min(n, head)) .. "\n</file_head>" }
  if n > head then
    parts[#parts + 1] = "<file_tail>\n" .. M.numbered(buf, math.max(head + 1, n - tail + 1), n) .. "\n</file_tail>"
  end
  parts[#parts + 1] = M.trees(buf)
  return table.concat(parts, "\n")
end

---Context block for a prompt: the profile when known, raw context otherwise.
---@return string block, boolean need_profile
function M.block(buf)
  local profile = cache.get_profile(M.file_key(buf))
  local s = "<file_info>\n" .. M.file_info(buf) .. "\n</file_info>\n"
  if profile then
    return s .. "<file_profile>\n" .. profile .. "\n</file_profile>", false
  end
  return s .. M.raw_context(buf), true
end

---Recurring line shapes of a large file: "<count>x  L<first>-L<last>  <template>".
function M.line_patterns(lines, limit)
  local stats, order = {}, {}
  for i = 1, math.min(#lines, 200000) do
    local body = vim.trim(lines[i])
    if body ~= "" then
      local t = mask.mask(body)
      local s = stats[t]
      if not s then
        s = { count = 0, first = i }
        stats[t] = s
        order[#order + 1] = t
      end
      s.count = s.count + 1
      s.last = i
    end
  end
  table.sort(order, function(a, b)
    return stats[a].count > stats[b].count
  end)
  local out = {}
  for i = 1, math.min(limit or 40, #order) do
    local s = stats[order[i]]
    out[#out + 1] = ("%7dx  L%d-L%d  %s"):format(s.count, s.first, s.last, order[i]:sub(1, 300))
  end
  return out
end

---The whole file, or head/tail/focus plus recurring line patterns when it is large.
---@param focus? integer[] {first, last}
function M.body(buf, focus)
  local n = vim.api.nvim_buf_line_count(buf)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local bytes = 0
  for _, l in ipairs(lines) do
    bytes = bytes + #l + 1
  end
  if bytes <= opts().body_max then
    return "<file_content>\n" .. M.numbered(buf, 1, n, focus) .. "\n</file_content>"
  end
  local parts = {
    ("<note>The file is large (%d lines, %s): only its head, tail%s and recurring line patterns are shown.</note>"):format(
      n,
      M.human(bytes),
      focus and ", the focus area" or ""
    ),
    "<file_head>\n" .. M.numbered(buf, 1, math.min(n, 150), focus) .. "\n</file_head>",
  }
  if focus then
    parts[#parts + 1] = "<focus_area>\n"
      .. M.numbered(buf, math.max(1, focus[1] - 100), math.min(n, focus[2] + 100), focus)
      .. "\n</focus_area>"
  end
  parts[#parts + 1] = "<file_tail>\n" .. M.numbered(buf, math.max(1, n - 149), n, focus) .. "\n</file_tail>"
  parts[#parts + 1] = ('<line_patterns note="%sa%s etc. are masked values (timestamps, numbers, IPs, paths, quoted strings)">\n'):format(
    mask.OPEN,
    mask.CLOSE
  ) .. table.concat(M.line_patterns(lines), "\n") .. "\n</line_patterns>"
  return table.concat(parts, "\n")
end

---Decoded packets for .pcap/.pcapng files (the buffer itself is binary noise).
function M.pcap_body(buf)
  local path = M.file_key(buf)
  if not (M.on_disk(buf) and (path:match("%.pcap$") or path:match("%.pcapng$"))) then
    return nil
  end
  local cmd = vim.fn.executable("tcpdump") == 1 and { "tcpdump", "-nn", "-tttt", "-X", "-r", path, "-c", "300" }
    or vim.fn.executable("tshark") == 1 and { "tshark", "-r", path, "-x", "-c", "300" }
    or nil
  if not cmd then
    return nil
  end
  local res = vim.system(cmd, { text = true }):wait(15000)
  return ("<decoded_capture tool=%q>\n%s\n</decoded_capture>"):format(
    cmd[1],
    (res.stdout or ""):sub(1, opts().body_max)
  )
end

M.sensitive = {
  "%.env",
  "secret",
  "credential",
  "passw",
  "token",
  "id_rsa",
  "id_ed25519",
  "%.pem$",
  "%.key$",
  "%.p12$",
  "%.kdbx$",
}

function M.is_sensitive(path)
  local name = vim.fn.fnamemodify(path, ":t"):lower()
  for _, p in ipairs(M.sensitive) do
    if name:find(p) then
      return true
    end
  end
  return false
end

local function is_binary(path)
  local f = io.open(path, "rb")
  if not f then
    return true
  end
  local head = f:read(1024) or ""
  f:close()
  return head:find("%z") ~= nil
end

---Files this file references by *relative* path (compose volumes/build dirs, includes...).
---Absolute paths are ignored so a log mentioning ~/.ssh/config can't leak it; so are
---files outside the file's directory and cwd, secrets and binaries.
function M.related_files(buf)
  if not M.on_disk(buf) then
    return ""
  end
  local self = M.file_key(buf)
  local roots = { vim.fn.fnamemodify(self, ":h"), vim.fn.getcwd() }
  local found, seen, seen_cand, out = 0, { [self] = true }, {}, {}
  local function inside(p)
    for _, r in ipairs(roots) do
      if vim.startswith(p, r .. "/") then
        return true
      end
    end
  end
  local function add(p)
    if found >= opts().related_max or seen[p] then
      return
    end
    seen[p] = true
    if not inside(p) or M.is_sensitive(p) or vim.fn.filereadable(p) == 0 then
      return
    end
    local size = vim.fn.getfsize(p)
    if size <= 0 or size > 200000 or is_binary(p) then
      return
    end
    local lines = vim.fn.readfile(p, "", 200)
    found = found + 1
    out[#out + 1] = ("<related_file path=%q size=%q%s>\n%s\n</related_file>"):format(
      vim.fn.fnamemodify(p, ":~:."),
      M.human(size),
      #lines == 200 and ' shown="first 200 lines"' or "",
      table.concat(lines, "\n")
    )
  end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, 3000, false)) do
    for cand in line:gmatch("[%w%._%-/]*[/.][%w%._%-/]*[%w_]") do
      if not seen_cand[cand] and not cand:match("^/") then
        seen_cand[cand] = true
        for _, r in ipairs(roots) do
          local p = vim.fn.simplify(r .. "/" .. cand)
          if vim.fn.isdirectory(p) == 1 then
            add(p .. "/Dockerfile")
            add(p .. "/Containerfile")
          else
            add(p)
          end
        end
      end
    end
    if found >= opts().related_max then
      break
    end
  end
  return table.concat(out, "\n")
end

---Everything a whole-file request needs.
---@param focus? integer[]
function M.whole(buf, focus)
  local key = M.file_key(buf)
  local parts = { "<file_info>\n" .. M.file_info(buf) .. "\n</file_info>" }
  local profile = cache.get_profile(key)
  if profile then
    parts[#parts + 1] = "<file_profile>\n" .. profile .. "\n</file_profile>"
  end
  parts[#parts + 1] = M.trees(buf)
  parts[#parts + 1] = M.related_files(buf)
  parts[#parts + 1] = M.pcap_body(buf) or M.body(buf, focus)
  return table.concat(parts, "\n")
end

return M
