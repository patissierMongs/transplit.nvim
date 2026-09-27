-- Side-by-side translation, scroll/cursor-bound to the source window.
--
-- Only the page around the cursor (± one page) is translated, extending as you scroll;
-- in whole-file mode the rest of the file is walked once with a few requests in flight.
-- Lines are masked (transplit.mask) and translated as unique templates, so the pane
-- always has exactly one line per source line with the source's values and indentation.
local cache = require("transplit.cache")
local config = require("transplit.config")
local context = require("transplit.context")
local llm = require("transplit.llm")
local mask = require("transplit.mask")
local ui = require("transplit.ui")

local M = {}

local ns = vim.api.nvim_create_namespace("transplit")
local sessions = ui.sessions

---Last raw model response, for debugging: :lua print(require("transplit.translate").last_response)
M.last_response = nil

function M.system_prompt(need_profile)
  local t = config.options.target
  return table.concat({
    "You translate lines of a file (logs, man pages, config files such as Dockerfile/compose/YAML, docs, command output)",
    "into " .. t .. ", using the provided file context so terminology fits the file's domain and project.",
    "In config files and code, translate comments and prose only; keep keys, values and syntax unchanged.",
    "The user message has <file_info>, then either <file_profile> or raw orientation context",
    "(<file_head>, <file_tail>, <directory_tree>), then <around_cursor> (numbered lines, for meaning only),",
    "then <translate>: a JSON array of strings to translate.",
    "Tokens like " .. mask.OPEN .. "a" .. mask.CLOSE .. " are placeholders for values: copy every one exactly;",
    "never translate, drop or duplicate them.",
    "Keep markup, punctuation, colons, parentheses, indentation and leading/trailing whitespace as in the source.",
    "Keep code identifiers, function names, directives, CLI flags and field labels like 'client:' untranslated.",
    "Use concise, natural technical " .. t .. ".",
    "Respond with ONLY a JSON object, no code fences:",
    need_profile
        and ('{"profile": string, "lines": [...]}. "profile" is 3-6 English sentences for future requests: what this file is,' .. " its format/line structure, the project/domain it belongs to, and identifiers/field labels that must stay" .. " untranslated (human-readable messages such as error descriptions should still be translated).")
      or '{"lines": [...]}.',
    '"lines" must have exactly as many strings as <translate>, in the same order.',
  }, " ")
end

---@return string text, boolean done, string template
function M.translate_line(key, line)
  local lead, body, trail = mask.split_ws(line)
  local tmpl, vals = mask.mask(body)
  if mask.is_trivial(tmpl) then
    return line, true, tmpl
  end
  local tr = cache.get_translation(key, tmpl)
  if tr then
    return lead .. vim.trim(mask.unmask(tr, vals)) .. trail, true, tmpl
  end
  return line, false, tmpl
end

---Parse a model response into the translated list (and profile), or nil.
---@return string[]?, string?
function M.parse_response(text, n)
  local s, e = (text or ""):find("{.*}")
  local ok, obj = pcall(vim.json.decode, s and text:sub(s, e) or "")
  if not (ok and type(obj) == "table" and type(obj.lines) == "table" and #obj.lines == n) then
    return nil
  end
  local profile = type(obj.profile) == "string" and obj.profile ~= "" and obj.profile or nil
  return obj.lines, profile
end

---Render translated (or placeholder) lines for [first, last] (1-based).
local function render(sess, first, last)
  if not vim.api.nvim_buf_is_valid(sess.tbuf) then
    return
  end
  local src = vim.api.nvim_buf_get_lines(sess.sbuf, first - 1, last, false)
  local out, pending = {}, {}
  for i, line in ipairs(src) do
    local text, done = M.translate_line(sess.key, line)
    out[i] = text
    pending[i] = not done
  end
  ui.set_lines(sess.tbuf, first - 1, last, out)
  vim.api.nvim_buf_clear_namespace(sess.tbuf, ns, first - 1, last)
  for i = 1, #src do
    if pending[i] then
      vim.api.nvim_buf_set_extmark(sess.tbuf, ns, first + i - 2, 0, { line_hl_group = "Comment" })
    end
  end
end

local function sync_length(sess)
  local n = vim.api.nvim_buf_line_count(sess.sbuf)
  if n ~= vim.api.nvim_buf_line_count(sess.tbuf) then
    render(sess, 1, n)
    ui.set_lines(sess.tbuf, n, -1, {}) -- drop trailing lines if the source shrank
  end
end

---Visible page, the page ± one page, and the cursor line.
local function page_range(sess)
  if not vim.api.nvim_win_is_valid(sess.swin) then
    return
  end
  -- nvim_win_call only passes through a single return value
  local r = vim.api.nvim_win_call(sess.swin, function()
    return { vim.fn.line("w0"), vim.fn.line("w$"), vim.fn.line(".") }
  end)
  local n = vim.api.nvim_buf_line_count(sess.sbuf)
  local h = r[2] - r[1] + 1
  return r[1], r[2], math.max(1, r[1] - h), math.min(n, r[2] + h), r[3]
end

local request -- forward decl

local function launch(sess, todo, cur)
  for _, t in ipairs(todo) do
    sess.inflight[t] = true
  end
  sess.jobs = sess.jobs + 1
  local n = vim.api.nvim_buf_line_count(sess.sbuf)
  local c = config.options.translate.context
  local ctx, need_profile = context.block(sess.sbuf)
  local user = ctx
    .. "\n<around_cursor>\n"
    .. context.numbered(sess.sbuf, math.max(1, cur - c), math.min(n, cur + c), { cur, cur })
    .. "\n</around_cursor>\n<translate>\n"
    .. vim.json.encode(todo)
    .. "\n</translate>"

  llm.request({ kind = "translate", system = M.system_prompt(need_profile), user = user }, function(text, err)
    sess.jobs = sess.jobs - 1
    for _, t in ipairs(todo) do
      sess.inflight[t] = nil
    end
    if not sessions[sess.sbuf] then
      return
    end
    M.last_response = text
    local arr, profile = M.parse_response(text, #todo)
    if not arr and #todo > 4 then
      -- usually the model merged/split lines of wrapped prose: retry in smaller batches
      sess.batch = math.max(4, math.floor(#todo / 2))
      sess.scan = 1
      return request(sess)
    end
    if arr and need_profile and profile then
      cache.set_profile(sess.key, profile)
    end
    local bad = 0
    for i, tmpl in ipairs(todo) do
      if arr and mask.valid(tmpl, arr[i]) then
        cache.set_translation(sess.key, tmpl, arr[i])
      else
        -- don't hammer the LLM with the same input; :TransSplitRetry clears this
        sess.failed[tmpl] = true
        bad = bad + 1
      end
    end
    if arr then
      cache.save()
    else
      vim.notify(
        "transplit: " .. (err or "unexpected response (see require('transplit.translate').last_response)"),
        vim.log.levels.WARN
      )
    end
    if bad > 0 then
      sess.warn = "⚠ " .. config.msg("failed_patterns"):format(bad)
    end
    request(sess)
  end)
end

request = function(sess)
  if not vim.api.nvim_buf_is_valid(sess.tbuf) then
    return
  end
  local vfirst, vlast, first, last, cur = page_range(sess)
  if not vfirst then
    return
  end
  render(sess, first, last)
  local o = config.options
  local n = vim.api.nvim_buf_line_count(sess.sbuf)
  local batch = sess.batch or o.translate.batch

  while sess.jobs < (sess.whole and o.translate.parallel or 1) do
    if sess.jobs > 0 and not cache.get_profile(sess.key) then
      break -- let the first call produce the profile the others will reuse
    end
    local todo, seen = {}, {}
    local function want(line)
      local _, done, tmpl = M.translate_line(sess.key, line)
      if not done and not seen[tmpl] and not sess.inflight[tmpl] and not sess.failed[tmpl] then
        seen[tmpl] = true
        todo[#todo + 1] = tmpl
      end
    end
    local function collect(a, b)
      for _, line in ipairs(vim.api.nvim_buf_get_lines(sess.sbuf, a - 1, b, false)) do
        if #todo >= batch then
          return
        end
        want(line)
      end
    end
    -- cursor line first, then the visible page, then the surrounding pages
    collect(cur, cur)
    collect(vfirst, vlast)
    collect(first, last)
    -- whole-file mode: walk the rest once; queued/in-flight lines are covered by their job
    while sess.whole and #todo < batch and sess.scan <= n do
      local chunk = vim.api.nvim_buf_get_lines(sess.sbuf, sess.scan - 1, math.min(n, sess.scan + 499), false)
      for _, line in ipairs(chunk) do
        if #todo >= batch then
          break
        end
        want(line)
        sess.scan = sess.scan + 1
      end
    end
    if #todo == 0 then
      break
    end
    launch(sess, todo, cur)
  end

  if sess.whole and sess.jobs == 0 and sess.scan > n and not sess.rendered_all then
    -- off-screen lines are otherwise only redrawn when scrolled to; draw them once so
    -- searching the translation pane finds everything
    sess.rendered_all = true
    render(sess, 1, n)
  end
  if sess.jobs > 0 then
    local progress = sess.whole
        and n > 0
        and (" %s %d%%"):format(config.msg("whole"), math.floor(math.min(sess.scan - 1, n) * 100 / n))
      or ""
    ui.set_winbar(
      sess.twin,
      "⏳ " .. config.msg("translating") .. progress .. (sess.jobs > 1 and (" ×" .. sess.jobs) or "") .. "…"
    )
  else
    ui.set_winbar(sess.twin, sess.warn or (o.target .. (sess.whole and (" · " .. config.msg("whole")) or "")))
  end
end

local function close(sbuf)
  local sess = sessions[sbuf]
  if not sess then
    return
  end
  sessions[sbuf] = nil
  pcall(vim.api.nvim_del_augroup_by_id, sess.group)
  if vim.api.nvim_win_is_valid(sess.swin) then
    vim.wo[sess.swin].scrollbind = false
    vim.wo[sess.swin].cursorbind = false
  end
  if vim.api.nvim_win_is_valid(sess.twin) then
    vim.api.nvim_win_close(sess.twin, true)
  end
end

---Toggle the translation pane for the current buffer.
---@param whole? boolean translate the entire file instead of the pages around the cursor
function M.toggle(whole)
  local sbuf = ui.source_buf()
  local existing = sessions[sbuf]
  if existing then
    if whole and not existing.whole then
      existing.whole, existing.scan = true, 1
      return request(existing)
    end
    return close(sbuf)
  end
  local swin = vim.fn.bufwinid(sbuf)

  local tbuf = vim.api.nvim_create_buf(false, true)
  vim.bo[tbuf].bufhidden = "wipe"
  vim.bo[tbuf].filetype = vim.bo[sbuf].filetype -- same syntax highlighting
  vim.api.nvim_buf_set_name(tbuf, "transplit://" .. vim.fn.fnamemodify(context.file_key(sbuf), ":t") .. "#" .. tbuf)

  vim.api.nvim_set_current_win(swin)
  vim.cmd("rightbelow vsplit")
  local twin = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(twin, tbuf)

  local sess = {
    sbuf = sbuf,
    swin = swin,
    tbuf = tbuf,
    twin = twin,
    key = context.file_key(sbuf),
    whole = whole == true,
    scan = 1,
    jobs = 0,
    inflight = {},
    failed = {},
  }
  sessions[sbuf] = sess
  render(sess, 1, vim.api.nvim_buf_line_count(sbuf))

  for _, w in ipairs({ swin, twin }) do
    -- wrapped lines would break line-for-line alignment
    vim.wo[w].wrap = false
    vim.wo[w].scrollbind = true
    vim.wo[w].cursorbind = true
    vim.wo[w].number = vim.wo[swin].number
    vim.wo[w].relativenumber = false
  end
  ui.set_winbar(twin, config.options.target)
  local top = vim.api.nvim_win_call(swin, function()
    return vim.fn.line("w0")
  end)
  vim.api.nvim_win_call(twin, function()
    vim.fn.winrestview({ topline = top })
  end)
  vim.cmd("syncbind")
  vim.api.nvim_set_current_win(swin)

  sess.group = vim.api.nvim_create_augroup("transplit_" .. sbuf, { clear = true })
  local timer = assert(vim.uv.new_timer())
  local function schedule()
    timer:stop()
    timer:start(
      250,
      0,
      vim.schedule_wrap(function()
        if sessions[sbuf] then
          sync_length(sess)
          request(sess)
        end
      end)
    )
  end
  vim.api.nvim_create_autocmd("WinScrolled", { group = sess.group, callback = schedule })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufReadPost", "FileChangedShellPost" }, {
    group = sess.group,
    buffer = sbuf,
    callback = schedule,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = sess.group,
    callback = function(ev)
      local w = tonumber(ev.match)
      if w == twin or w == swin then
        vim.schedule(function()
          close(sbuf)
        end)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = sess.group,
    buffer = tbuf,
    callback = function()
      vim.schedule(function()
        close(sbuf)
      end)
    end,
  })

  request(sess)
end

---Retry templates that failed validation in every open pane.
function M.retry()
  for _, sess in pairs(sessions) do
    sess.failed, sess.warn, sess.scan, sess.rendered_all = {}, nil, 1, false
    request(sess)
  end
end

return M
