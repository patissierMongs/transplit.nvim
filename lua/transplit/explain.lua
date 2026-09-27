-- Technical explanation of the cursor line / selection, or of the whole file,
-- streamed into the shared side window.
local config = require("transplit.config")
local context = require("transplit.context")
local llm = require("transplit.llm")
local ui = require("transplit.ui")

local M = {}

local common = {
  "The file may be a log, a man page or --help output, a config file (Dockerfile, compose, systemd unit, nginx,",
  "YAML/TOML...), source code, a packet capture, docs or command output; adapt the explanation to what it is.",
  "Context tags: <file_info>, optional <file_profile> or <file_head>/<file_tail>, <directory_tree>,",
  "<related_file> (files this file references), and the content itself.",
  "Keep identifiers, commands and config directives in their original form. Cite line numbers like L123.",
  "State uncertainty briefly when the context is insufficient; do not invent facts about files you were not shown.",
}

---@param whole boolean
function M.system_prompt(whole)
  local t = config.options.target
  local h = config.msg(whole and "sections_file" or "sections_line")
  local intro
  if whole then
    intro = {
      "You are a senior engineer giving a colleague an overview of a whole file, in " .. t .. ".",
      "The content is in <file_content>, or <file_head>/<file_tail>/<line_patterns> when large, or <decoded_capture>.",
      "Use Markdown with exactly these '## ' section headings:",
      ("## %s (what the file is and its role in the project, 3-5 sentences),"):format(h[1]),
      ("## %s (major sections/blocks with line ranges like L10-L42; for logs: kinds of events and the time span),"):format(
        h[2]
      ),
      ("## %s (the important settings, logic or events, concretely),"):format(h[3]),
      ("## %s (problems, risks, anomalies, misconfigurations; for logs: errors by frequency and likely causes),"):format(
        h[4]
      ),
      ("## %s (commands to verify, related files, settings or man pages to look at)."):format(h[5]),
      "Mention it if the content was truncated.",
    }
  else
    intro = {
      "You are a senior engineer explaining a specific part of a file to a colleague, in " .. t .. ".",
      "The content is in <excerpt>: numbered lines where the target lines are marked with '>>'.",
      "Explain the target lines using the surrounding lines and file/project context. Be concrete and concise.",
      "Use Markdown with these '## ' section headings (omit a section only if it truly does not apply):",
      ("## %s (what the lines say or do; field by field for structured lines such as log entries or option syntax),"):format(
        h[1]
      ),
      ("## %s (how it relates to nearby lines, the section it is in, and the project),"):format(h[2]),
      ("## %s (for logs: likely causes and how to verify/fix; for options/config: typical usage examples,"):format(
        h[3]
      ),
      "defaults, pitfalls and interactions; use shell commands or config snippets in code blocks),",
      ("## %s (related options, settings, man pages or docs to look at next)."):format(h[4]),
    }
  end
  return table.concat(vim.list_extend(intro, common), " ")
end

local explain_buf

local function stream(header, system, user)
  if not (explain_buf and vim.api.nvim_buf_is_valid(explain_buf)) then
    explain_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[explain_buf].filetype = "markdown"
    vim.bo[explain_buf].bufhidden = "hide"
    vim.api.nvim_buf_set_name(explain_buf, "transplit://explain")
  end
  local ebuf = explain_buf
  local ewin = ui.side_window(ebuf)
  local acc = ""
  local function draw(extra)
    if vim.api.nvim_buf_is_valid(ebuf) then
      local lines = vim.list_extend(vim.deepcopy(header), vim.split(acc .. (extra or ""), "\n"))
      vim.api.nvim_buf_set_lines(ebuf, 0, -1, false, lines)
    end
  end
  draw("⏳ " .. config.msg("analyzing"))
  ui.set_winbar(ewin, config.msg("explanation"))
  vim.api.nvim_win_set_cursor(ewin, { 1, 0 })

  llm.request({
    kind = "explain",
    system = system,
    user = user,
    on_delta = function(d)
      acc = acc .. d
      draw()
    end,
  }, function(text, err)
    if err == "cancelled" then
      return
    end
    if not text then
      acc = acc .. "\n\n⚠ " .. config.msg("failed") .. ": " .. (err or "?")
    end
    draw()
  end)
end

---Explain lines [first, last] of the current buffer (default: the cursor line).
---@param first? integer
---@param last? integer
function M.lines(first, last)
  local buf = ui.source_buf()
  first = first or vim.api.nvim_win_get_cursor(0)[1]
  last = last or first
  local n = vim.api.nvim_buf_line_count(buf)
  local r = config.options.explain.radius
  local ctx = context.block(buf)
  local user = ctx
    .. "\n<excerpt>\n"
    .. context.numbered(buf, math.max(1, first - r), math.min(n, last + r), { first, last })
    .. "\n</excerpt>"
  local where = first == last and tostring(first) or (first .. "-" .. last)
  local header = { ("# %s:%s"):format(vim.fn.fnamemodify(context.file_key(buf), ":~:."), where), "" }
  for _, l in ipairs(vim.api.nvim_buf_get_lines(buf, first - 1, math.min(last, first + 4), false)) do
    header[#header + 1] = "> " .. l
  end
  header[#header + 1] = ""
  stream(header, M.system_prompt(false), user)
end

---Explain the whole current file.
function M.file()
  local buf = ui.source_buf()
  local title = "# " .. vim.fn.fnamemodify(context.file_key(buf), ":~:.") .. " " .. config.msg("whole_file")
  stream({ title, "" }, M.system_prompt(true), context.whole(buf))
end

return M
