local d = require("transplit.visual.doc")

local function msg(key)
  return "<" .. key .. ">"
end

local doc = table.concat({
  "# Title",
  "",
  "Summary with **bold** and `code`.",
  "",
  "```d2",
  'a -> b: "x"',
  "```",
  "",
  "| a | b |",
  "|---|---|",
  "| 1 | 2 |",
  "",
  "```mermaid",
  "pie",
  "```",
  "",
  "```bash",
  "echo hi",
  "```",
  "* item",
}, "\n")

describe("visual.doc", function()
  it("parses fenced blocks with their line ranges", function()
    local blocks = d.parse_blocks(doc)
    assert.are.equal(3, #blocks)
    assert.are.same(
      { "d2", 5, 7, { 'a -> b: "x"' } },
      { blocks[1].lang, blocks[1].first, blocks[1].last, blocks[1].code }
    )
    assert.are.equal("mermaid", blocks[2].lang)
    assert.are.equal("bash", blocks[3].lang)
  end)

  it("ignores an unterminated block", function()
    assert.are.equal(0, #d.parse_blocks("```d2\na -> b"))
  end)

  it("unwraps a document fenced as a whole", function()
    assert.are.equal("# T\n\n```d2\nx\n```", d.clean("```markdown\n# T\n\n```d2\nx\n```\n```"))
    assert.are.equal("# T", d.clean("  # T \n"))
    -- commentary before the document (seen from the fix prompt) is dropped
    assert.are.equal("# T\nbody", d.clean("The error was caused by $host.\n\n# T\nbody"))
    -- text without any heading is kept as-is
    assert.are.equal("no heading", d.clean("no heading"))
  end)

  it("finds non-ASCII D2 labels but ignores comments", function()
    assert.is_nil((d.non_ascii_line({ "# 주석", 'a -> b: "ok"' })))
    local n, line = d.non_ascii_line({ 'a -> b: "ok"', 'b: "추정"' })
    assert.are.equal(2, n)
    assert.are.equal('b: "추정"', line)
  end)

  it("renders D2 as text in the nvim view", function()
    local blocks = d.parse_blocks(doc)
    blocks[1].ascii = { "[a] --> [b]" }
    local view = d.to_view(doc, blocks, msg)
    local text = table.concat(view, "\n")
    assert.is_truthy(text:find("```text\n[a] --> [b]\n```", 1, true))
    assert.is_truthy(text:find("<mermaid_in_browser>", 1, true))
    assert.is_truthy(text:find("```bash\necho hi\n```", 1, true))
  end)

  it("shows D2 errors with the source in the view", function()
    local blocks = d.parse_blocks(doc)
    blocks[1].err = "line 1:9: maps must be terminated with }"
    local text = table.concat(d.to_view(doc, blocks, msg), "\n")
    assert.is_truthy(text:find("<d2_error>: line 1:9", 1, true))
    assert.is_truthy(text:find('```d2\na -> b: "x"\n```', 1, true))
  end)

  it("converts to Org with SVG images", function()
    local blocks = d.parse_blocks(doc)
    blocks[1].svg_path = "/tmp/1.svg"
    local org = d.to_org(doc, blocks, "T", msg)
    assert.are.equal("#+title: T", org[1])
    local text = table.concat(org, "\n")
    assert.is_truthy(text:find("\n* Title\n", 1, true))
    assert.is_truthy(text:find("*bold* and ~code~", 1, true))
    assert.is_truthy(text:find("[[file:/tmp/1.svg]]", 1, true))
    assert.is_truthy(text:find("\n|-\n", 1, true))
    assert.is_truthy(text:find("#+begin_src bash\necho hi\n#+end_src", 1, true))
    assert.is_truthy(text:find("\n- item", 1, true))
  end)

  it("quotes strings for Emacs Lisp", function()
    assert.are.equal([["a\"b\\c"]], d.elisp_str([[a"b\c]]))
  end)
end)
