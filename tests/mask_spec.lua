local mask = require("transplit.mask")

local nginx_error =
  '2026/09/18 10:00:02 [crit] 812#812: *2 open() "/usr/share/nginx/html/favicon.ico" failed (2: No such file or directory), client: 10.0.0.2, server: localhost, request: "GET /favicon.ico HTTP/1.1", host: "example.com"'
local access = '192.168.0.1 - - [18/Sep/2026:10:12:01 +0900] "GET /a?x=1 HTTP/1.1" 200 615 "-" "curl/8.9"'

describe("mask", function()
  it("round-trips any line exactly", function()
    for _, line in ipairs({
      nginx_error,
      access,
      "2026/09/18 10:00:05 [emerg] 1#1: bind() to 0.0.0.0:80 failed (98: Address already in use)",
      "  --with-http_ssl_module            enable ngx_http_ssl_module",
      "see https://nginx.org/en/docs/ for details, 100% free",
      "",
    }) do
      local tmpl, vals = mask.mask(line)
      assert.are.equal(line, mask.unmask(tmpl, vals))
    end
  end)

  it("gives lines that differ only in values the same template", function()
    local a = mask.mask(nginx_error)
    local b = mask.mask((nginx_error:gsub("10:00:02", "11:59:59"):gsub("%*2 ", "*7 "):gsub("10%.0%.0%.2", "10.0.0.9")))
    assert.are.equal(a, b)
  end)

  it("keeps the natural-language part translatable", function()
    local tmpl = mask.mask(nginx_error)
    assert.is_truthy(tmpl:find("No such file or directory", 1, true))
    assert.is_falsy(tmpl:find("10.0.0.2", 1, true))
    assert.is_falsy(tmpl:find("favicon", 1, true))
  end)

  it("marks value-only lines as trivial", function()
    assert.is_true(mask.is_trivial((mask.mask(access))))
    assert.is_false(mask.is_trivial((mask.mask(nginx_error))))
  end)

  it("numbers placeholders a..z then aa..", function()
    assert.are.equal(mask.OPEN .. "a" .. mask.CLOSE, mask.token(1))
    assert.are.equal(mask.OPEN .. "z" .. mask.CLOSE, mask.token(26))
    assert.are.equal(mask.OPEN .. "aa" .. mask.CLOSE, mask.token(27))
    local vals = {}
    for i = 1, 30 do
      vals[i] = tostring(i)
    end
    assert.are.equal("27-30", mask.unmask(mask.token(27) .. "-" .. mask.token(30), vals))
  end)

  it("accepts a translation only with the same placeholders", function()
    local src = "open() " .. mask.token(1) .. " failed (" .. mask.token(2) .. " No such file)"
    assert.is_true(mask.valid(src, mask.token(1) .. " 열기 실패 (" .. mask.token(2) .. " 파일 없음)"))
    -- reordering is fine, dropping or duplicating is not
    assert.is_true(mask.valid(src, mask.token(2) .. " / " .. mask.token(1)))
    assert.is_false(mask.valid(src, mask.token(1) .. " 실패"))
    assert.is_false(mask.valid(src, mask.token(1) .. mask.token(1) .. mask.token(2)))
    assert.is_false(mask.valid(src, nil))
  end)

  it("splits off indentation", function()
    local lead, body, trail = mask.split_ws("    tar -x [-f ARCHIVE]  ")
    assert.are.same({ "    ", "tar -x [-f ARCHIVE]", "  " }, { lead, body, trail })
  end)
end)
