-- Visualization of a file (or a range) as diagrams.
--
-- The LLM writes a Markdown document whose diagrams are D2 and, only where D2 has no
-- equivalent (packet layouts, pie and xy charts), Mermaid. Every D2 block is compiled
-- locally, which validates it (errors go straight back to the LLM, at most twice) and
-- produces:
--   * a text rendering shown inline in nvim (labels are kept ASCII so it lines up)
--   * an SVG shown in Emacs (ge) or a browser page (gb, which also renders Mermaid and
--     reports Mermaid errors back for the same automatic fix)
-- In the view: gs edits the source Markdown; :w there re-renders every view.
local config = require("transplit.config")
local context = require("transplit.context")
local d = require("transplit.visual.doc")
local llm = require("transplit.llm")
local server = require("transplit.visual.server")
local ui = require("transplit.ui")

local M = {}

local MAX_FIXES = 2

---@type table<string, table>
local docs = {}
---@type table?
M.last_doc = nil
---@type string?
M.last_url = nil

function M.system_prompt()
  local t = config.options.target
  return table.concat({
    "You create visualizations of a file and its project for an engineer, as a Markdown document written in",
    t .. ".",
    "Input: <file_info>, optional <file_profile>, <directory_tree>, <related_file> (files referenced by this file), and the",
    "file itself as <file_content> (or <file_head>/<file_tail>/<line_patterns> when large, or <decoded_capture> for packet",
    "captures), optionally <focus>.",
    "First identify what the input is, then choose the visualizations that make it easiest to understand:",
    "- Container/orchestration configs (docker compose, Kubernetes): architecture diagram (direction: right) with a container",
    "per network or namespace, a node per service with its image, cylinder nodes for volumes, a host/internet node, edges for",
    'published ports labeled like "127.0.0.1:8080 -> 80/tcp", depends_on edges (dashed), and real traffic edges inferred from',
    "related configs (e.g. nginx proxy_pass/upstream). Add a port mapping table (service | host ip:port | container port |",
    "protocol | exposed to), a volumes/networks table, and a sequence diagram of a typical request through the stack.",
    "- Dockerfile: diagram of build stages and what is copied between them, plus a table of instructions/layers.",
    "- Web server/proxy configs (nginx, Caddy, HAProxy, Traefik): routing diagram listen/server_name -> location matching ->",
    "upstream/backends, TLS termination, redirects; a routes table.",
    "- Source code: control-flow diagram of the focused function or the main entry point (decisions as diamond shapes, error",
    "paths), a sequence diagram for interactions between components/IO, class or sql_table shapes when data structures are",
    "central. Name functions and lines (L42) in captions.",
    "- Packet captures/tcpdump/tshark output: sequence diagram of the conversation between endpoints (handshake, flags,",
    "seq/ack, lengths, timing); a Mermaid packet-beta diagram of a representative packet's header with real values; a table",
    "decoding the payload hex dump (offset | bytes | field | value | meaning); the reconstructed application-layer message",
    "(e.g. the HTTP request) in a code block.",
    "- Logs: diagram of the request/event flow the log implies, a table of top error patterns with counts and time ranges;",
    "a Mermaid pie of levels/error kinds or xychart-beta of events over time only when that adds real insight.",
    "- Man pages/CLI help: diagram of the command's modes and option groups; table of the most useful options with examples.",
    "- SQL/schemas: sql_table shapes with relations. CI/Makefiles/build scripts: jobs/targets and dependencies. State",
    "machines: states and transitions. Anything else: pick what fits.",
    "Diagram language: D2 in ```d2 blocks. Use Mermaid (```mermaid) ONLY for packet-beta, pie and xychart-beta, which D2 lacks.",
    "D2 rules: one diagram per block. Keys use only ASCII letters, digits and underscores (a dot means nesting: never put",
    "dots, colons or spaces in keys). Labels are short ENGLISH/ASCII text in double quotes, because diagrams are also drawn as",
    "monospace text in a terminal where non-ASCII breaks alignment; put " .. t .. " explanations in captions,",
    "notes and tables instead. Line breaks inside quoted labels: \\n.",
    'Containers: net: "network: default" { web: "web\\nnginx:1.27" }. Refer across containers with dotted paths:',
    'host -> net.web: "127.0.0.1:8080 -> 80/tcp". Shapes: {shape: cylinder} volumes/databases, {shape: cloud} internet,',
    "{shape: person} users, {shape: queue}, {shape: diamond} decisions. Dashed edges: {style.stroke-dash: 3}.",
    "Sequence diagrams: 'shape: sequence_diagram' first, then actors in order, then messages a -> b: \"msg\".",
    "Tables: shape: sql_table with fields like 'id: int {constraint: primary_key}'. No icons, no markdown labels, no",
    "vars/imports/layout settings. Keep each diagram under ~30 nodes.",
    "Never put '$' in D2 labels (D2 substitutes variables): write nginx variables like $host as 'host' instead.",
    "Output ONLY the Markdown document, starting with '# <title>', no surrounding code fences.",
    "Structure: title, a 2-3 sentence summary, then for each visualization a '## ' heading, a one-line caption, the diagram,",
    "and tables/notes as needed. 2-4 diagrams total; quality over quantity.",
    ("Use only facts from the input; mark inferred items with '%s' in captions/tables, but with '(guess)' inside D2 labels:"):format(
      config.msg("guess")
    ),
    "D2 labels must never contain " .. t .. " or any other non-ASCII character (not even arrows like →; use ->).",
    "Keep identifiers, ports, paths and image names verbatim.",
  }, " ")
end

function M.fix_prompt()
  return table.concat({
    "You fix diagram syntax errors in a Markdown document.",
    "<document> is the document; <render_errors> lists errors per ```d2 or ```mermaid block, numbered separately per",
    "language in order of appearance. D2 error positions are line:column inside that block.",
    "Return the ENTIRE corrected document only, without surrounding code fences.",
    "Change only what is needed to make each failing diagram compile: quote labels, fix keys (ASCII letters, digits,",
    "underscores; no dots/colons/spaces), close braces, or replace an unsupported construct with a simpler equivalent.",
    "Keep D2 labels ASCII. Keep all other text unchanged.",
  }, " ")
end

---Readable D2 compile error: drop the temp-file path, keep "line:col: message".
function M.d2_error(stderr, src)
  local msgs = {}
  for line in (stderr or ""):gmatch("[^\n]+") do
    if line:match("^err:") then
      local m = line:gsub("^err:%s*", ""):gsub("failed to compile [^:]+: ", ""):gsub(vim.pesc(src) .. ":", "line ")
      msgs[#msgs + 1] = m
    end
  end
  return #msgs > 0 and table.concat(msgs, "; ") or vim.trim(stderr or "d2 failed")
end

---Compile every D2 block to SVG and to text; sets b.index, b.svg_path, b.ascii, b.err, b.warn.
local function compile_d2(doc, cb)
  local pending, k = 1, 0
  local function done()
    pending = pending - 1
    if pending == 0 then
      cb()
    end
  end
  for _, b in ipairs(doc.blocks) do
    if b.lang == "d2" then
      k = k + 1
      b.index = k
      local src = ("%s/%d.d2"):format(doc.dir, k)
      b.svg_path = ("%s/%d.svg"):format(doc.dir, k)
      vim.fn.writefile(b.code, src)
      local n, text = d.non_ascii_line(b.code)
      if n then
        b.warn = ("line %d: non-ASCII text in a label (%s); labels must be ASCII, move it to the caption or a table"):format(
          n,
          text
        )
      end
      pending = pending + 2
      vim.system(
        { "d2", "--theme=0", src, b.svg_path },
        { text = true },
        vim.schedule_wrap(function(r)
          if r.code ~= 0 then
            b.err = M.d2_error(r.stderr, src)
          end
          done()
        end)
      )
      vim.system(
        { "d2", src, "--stdout-format", "txt", "-" },
        { text = true },
        vim.schedule_wrap(function(r)
          if r.code == 0 and r.stdout and r.stdout ~= "" then
            -- d2 pads every line to the full width; with 'list' those spaces show as "-"
            b.ascii = vim.tbl_map(function(l)
              return (l:gsub("%s+$", ""))
            end, vim.split((r.stdout:gsub("%s+$", "")), "\n"))
          end
          done()
        end)
      )
    end
  end
  done()
end

local function view_status(doc)
  if vim.api.nvim_buf_is_valid(doc.view) then
    local text = (doc.status and doc.status ~= "") and doc.status or config.msg("visual_hint")
    ui.set_winbar(vim.fn.bufwinid(doc.view), config.msg("visual") .. " · " .. text)
  end
end

local function set_source(doc, markdown)
  doc.markdown = markdown
  local lines = vim.split(markdown, "\n")
  local sbuf = vim.fn.bufnr(doc.md_path)
  if sbuf ~= -1 and vim.api.nvim_buf_is_loaded(sbuf) then
    vim.api.nvim_buf_set_lines(sbuf, 0, -1, false, lines)
    vim.api.nvim_buf_call(sbuf, function()
      vim.cmd("silent noautocmd write!")
    end)
  else
    vim.fn.writefile(lines, doc.md_path)
  end
end

local function refresh_emacs(doc)
  if doc.emacs then
    vim.system({
      "emacsclient",
      "--eval",
      ("(let ((b (find-buffer-visiting %s))) (when b (with-current-buffer b (revert-buffer t t t) (clear-image-cache) (org-display-inline-images))))"):format(
        d.elisp_str(doc.org_path)
      ),
    })
  end
end

local render -- forward decl

local function request_fix(doc, errs)
  if doc.busy then
    return
  end
  if doc.fixes >= MAX_FIXES then
    doc.status = "⚠ " .. config.msg("fix_gave_up")
    return view_status(doc)
  end
  doc.fixes = doc.fixes + 1
  doc.busy = true
  doc.status = "⏳ " .. config.msg("fixing"):format(doc.fixes)
  view_status(doc)
  llm.request({
    kind = "visual",
    system = M.fix_prompt(),
    user = "<document>\n"
      .. doc.markdown
      .. "\n</document>\n<render_errors>\n"
      .. table.concat(errs, "\n")
      .. "\n</render_errors>",
  }, function(text, err)
    doc.busy = false
    if not text then
      doc.status = "⚠ " .. config.msg("fix_failed"):format(err or "?")
      return view_status(doc)
    end
    set_source(doc, d.clean(text))
    render(doc)
  end)
end

render = function(doc)
  doc.blocks = d.parse_blocks(doc.markdown)
  doc.status = "⏳ " .. config.msg("compiling")
  view_status(doc)
  compile_d2(doc, function()
    doc.version = doc.version + 1
    ui.set_lines(doc.view, 0, -1, d.to_view(doc.markdown, doc.blocks, config.msg))
    vim.fn.writefile(d.to_org(doc.markdown, doc.blocks, doc.title, config.msg), doc.org_path)
    refresh_emacs(doc)
    local errs = {}
    for _, b in ipairs(doc.blocks) do
      if b.err or b.warn then
        errs[#errs + 1] = ("- d2 block #%d: %s"):format(b.index, b.err or b.warn)
      end
    end
    doc.status = ""
    view_status(doc)
    if #errs > 0 then
      request_fix(doc, errs)
    end
  end)
end

local viewer_html
local function viewer()
  if not viewer_html then
    local dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h")
    viewer_html = table.concat(vim.fn.readfile(dir .. "/viewer.html"), "\n")
  end
  return (
    viewer_html
      :gsub("{{LOADING}}", config.msg("viewer_loading"))
      :gsub("{{ERROR}}", config.msg("viewer_error"))
      :gsub("{{DISCONNECTED}}", config.msg("viewer_disconnected"))
  )
end

local function handle(method, path, body)
  local tok, id, rest = path:match("^/(%x+)/(%x+)(.*)$")
  local doc = tok == server.token and docs[id]
  if not doc then
    return "404 Not Found", "text/plain", "not found"
  end
  rest = rest:gsub("%?.*$", "")
  if method == "GET" and (rest == "" or rest == "/") then
    return "200 OK", "text/html; charset=utf-8", viewer()
  elseif method == "GET" and rest == "/doc" then
    local json = vim.json.encode({
      version = doc.version,
      title = doc.title,
      status = doc.status or "",
      markdown = doc.markdown,
    })
    return "200 OK", "application/json", json
  elseif method == "GET" and rest:match("^/svg/%d+$") then
    local f = io.open(("%s/%s.svg"):format(doc.dir, rest:match("%d+")), "rb")
    if f then
      local svg = f:read("*a")
      f:close()
      return "200 OK", "image/svg+xml", svg
    end
  elseif method == "POST" and rest == "/error" then
    local ok, data = pcall(vim.json.decode, body)
    if ok and type(data) == "table" and data.version == doc.version and type(data.errors) == "table" then
      local errs = {}
      for _, e in ipairs(data.errors) do
        errs[#errs + 1] = ("- mermaid block #%d: %s"):format((tonumber(e.index) or 0) + 1, tostring(e.message))
      end
      if #errs > 0 then
        request_fix(doc, errs)
      end
    end
    return "204 No Content", "text/plain", ""
  end
  return "404 Not Found", "text/plain", "not found"
end

---@param doc? table the last visualization when nil
function M.open_browser(doc)
  doc = doc or M.last_doc
  if not doc then
    return
  end
  if not server.ensure(handle) then
    return vim.notify("transplit: could not start the local viewer server", vim.log.levels.ERROR)
  end
  local url = ("http://127.0.0.1:%d/%s/%s"):format(server.port, server.token, doc.id)
  M.last_url = url
  local cmd = config.options.visual.open_cmd
  if cmd then
    vim.system(vim.list_extend(vim.deepcopy(cmd), { url }), { detach = true })
  elseif vim.fn.executable("firefox") == 1 then
    vim.system({ "firefox", "--new-window", url }, { detach = true })
  else
    vim.ui.open(url)
  end
end

---@param doc? table the last visualization when nil
function M.open_emacs(doc)
  doc = doc or M.last_doc
  if not doc then
    return
  end
  if vim.fn.executable("emacsclient") == 0 then
    return vim.notify("transplit: emacsclient not found", vim.log.levels.WARN)
  end
  doc.emacs = true
  local el = (
    "(progn (find-file %s) (setq-local org-image-actual-width nil)"
    .. " (when (boundp 'org-image-max-width) (setq-local org-image-max-width 'window))"
    .. " (org-display-inline-images) (goto-char (point-min)))"
  ):format(d.elisp_str(doc.org_path))
  -- -a "": start the Emacs daemon if it is not running yet
  vim.system(
    { "emacsclient", "-c", "-n", "-a", "", "--eval", el },
    { text = true },
    vim.schedule_wrap(function(r)
      if r.code ~= 0 then
        vim.notify("transplit: emacsclient failed: " .. vim.trim(r.stderr or ""), vim.log.levels.WARN)
      end
    end)
  )
end

---Visualize the current file, focusing on [first, last] when given.
---@param first? integer
---@param last? integer
function M.run(first, last)
  if vim.fn.executable("d2") == 0 then
    return vim.notify("transplit: d2 not found (https://d2lang.com)", vim.log.levels.ERROR)
  end
  local buf = ui.source_buf()
  local focus = first and { first, last or first } or nil
  local user = context.whole(buf, focus)
  if focus then
    user = user
      .. ("\n<focus>Visualize primarily L%d-L%d (marked with >>), using the rest as context.</focus>"):format(
        focus[1],
        focus[2]
      )
  end

  local name = vim.fn.fnamemodify(context.file_key(buf), ":t"):gsub("[^%w%._%-]", "_")
  local id = server.hex(4)
  local dir = ("%s/%s-%s"):format(config.options.visual_dir, name, os.date("%Y%m%d-%H%M%S"))
  vim.fn.mkdir(dir, "p")
  local doc = {
    id = id,
    dir = dir,
    md_path = dir .. "/doc.md",
    org_path = dir .. "/doc.org",
    title = config.msg("visual") .. " · " .. name,
    markdown = "",
    blocks = {},
    version = 0,
    fixes = 0,
    busy = true,
    status = "⏳ " .. config.msg("generating"),
  }
  docs[id] = doc
  M.last_doc = doc

  doc.view = vim.api.nvim_create_buf(false, true)
  vim.bo[doc.view].filetype = "markdown"
  vim.bo[doc.view].bufhidden = "hide"
  vim.api.nvim_buf_set_name(doc.view, "transplit://visual/" .. name .. "-" .. id)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = doc.view, nowait = true, desc = desc })
  end
  map("gs", function()
    vim.cmd("belowright split " .. vim.fn.fnameescape(doc.md_path))
  end, "Edit visualization source")
  map("ge", function()
    M.open_emacs(doc)
  end, "Open in Emacs")
  map("gb", function()
    M.open_browser(doc)
  end, "Open in browser")
  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = doc.md_path,
    callback = function(ev)
      if not doc.busy then
        doc.markdown = table.concat(vim.api.nvim_buf_get_lines(ev.buf, 0, -1, false), "\n")
        doc.fixes = 0
        render(doc)
      end
    end,
  })

  local win = ui.side_window(doc.view)
  vim.wo[win].wrap = false -- text diagrams must not wrap
  ui.set_lines(doc.view, 0, -1, { "⏳ " .. config.msg("generating") })
  view_status(doc)

  local acc = ""
  llm.request({
    kind = "visual",
    system = M.system_prompt(),
    user = user,
    on_delta = function(delta)
      acc = acc .. delta
      ui.set_lines(doc.view, 0, -1, vim.split(acc, "\n"))
    end,
  }, function(text, err)
    doc.busy = false
    if not text then
      doc.status = "⚠ " .. config.msg("gen_failed"):format(err or "?")
      return view_status(doc)
    end
    set_source(doc, d.clean(text))
    render(doc)
  end)
end

return M
