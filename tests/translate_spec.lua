local cache = require("transplit.cache")
local config = require("transplit.config")
local mask = require("transplit.mask")
local translate = require("transplit.translate")

describe("translate", function()
  before_each(function()
    config.setup({ cache_file = vim.fn.tempname() .. "/cache.json" })
    cache.reset()
  end)

  it("reuses one template translation for every line of the same shape, with original values", function()
    local line1 = "2026/09/18 10:00:03 [crit] 812#812: *3 connect() failed (111: Connection refused)"
    local line2 = "2026/09/18 11:22:33 [warn] 9#9: *41 connect() failed (111: Connection refused)"
    local _, done, tmpl = translate.translate_line("k", line1)
    assert.is_false(done)
    local translated = tmpl:gsub("connect%(%) failed", "connect() 실패"):gsub("Connection refused", "연결 거부")
    cache.set_translation("k", tmpl, translated)

    local out1 = translate.translate_line("k", line1)
    local out2 = translate.translate_line("k", line2)
    assert.are.equal("2026/09/18 10:00:03 [crit] 812#812: *3 connect() 실패 (111: 연결 거부)", out1)
    assert.are.equal("2026/09/18 11:22:33 [warn] 9#9: *41 connect() 실패 (111: 연결 거부)", out2)
  end)

  it("keeps indentation even if the model changes it", function()
    local line = "      --prefix=PATH    set installation prefix  "
    local _, _, tmpl = translate.translate_line("k", line)
    cache.set_translation("k", tmpl, "  " .. tmpl:gsub("set installation prefix", "설치 경로 지정") .. "\n")
    local out = translate.translate_line("k", line)
    assert.are.equal("      --prefix=PATH    설치 경로 지정  ", out)
  end)

  it("passes value-only lines through untouched", function()
    local line = '10.0.0.1 - - [18/Sep/2026:10:12:01 +0900] "GET / HTTP/1.1" 200 615'
    local out, done = translate.translate_line("k", line)
    assert.is_true(done)
    assert.are.equal(line, out)
  end)

  it("parses responses, tolerating code fences, and rejects a wrong line count", function()
    local lines, profile = translate.parse_response('```json\n{"profile": "p", "lines": ["a", "b"]}\n```', 2)
    assert.are.same({ "a", "b" }, lines)
    assert.are.equal("p", profile)
    assert.is_nil(translate.parse_response('{"lines": ["a"]}', 2))
    assert.is_nil(translate.parse_response("not json", 1))
    assert.is_nil(translate.parse_response(nil, 1))
  end)

  it("asks for a profile only when none is cached", function()
    assert.is_truthy(translate.system_prompt(true):find('"profile"', 1, true))
    assert.is_falsy(translate.system_prompt(false):find('"profile"', 1, true))
    assert.is_truthy(translate.system_prompt(false):find(mask.token(1), 1, true))
  end)
end)
