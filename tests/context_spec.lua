local config = require("transplit.config")
local context = require("transplit.context")

local function scratch(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

describe("context", function()
  before_each(function()
    config.setup({ cache_file = vim.fn.tempname() .. "/cache.json" })
    require("transplit.cache").reset()
  end)

  it("formats sizes", function()
    assert.are.equal("512B", context.human(512))
    assert.are.equal("1.5K", context.human(1536))
    assert.are.equal("?", context.human(-1))
  end)

  it("numbers lines and marks the target range", function()
    local buf = scratch({ "one", "two", "three" })
    local out = vim.split(context.numbered(buf, 1, 3, { 2, 2 }), "\n")
    assert.are.same({ "      1| one", ">>    2| two", "      3| three" }, out)
  end)

  it("keys unnamed buffers by content", function()
    local a = context.file_key(scratch({ "same output" }))
    local b = context.file_key(scratch({ "same output" }))
    local c = context.file_key(scratch({ "other output" }))
    assert.are.equal(a, b)
    assert.are_not.equal(a, c)
    assert.is_truthy(a:match("^%[stdin %x+%]$"))
  end)

  it("recognizes sensitive file names", function()
    for _, p in ipairs({ ".env", "prod.env", "id_rsa", "server.key", "db-password.txt", "api_token" }) do
      assert.is_true(context.is_sensitive(p), p)
    end
    for _, p in ipairs({ "nginx.conf", "Dockerfile", "compose.yaml" }) do
      assert.is_false(context.is_sensitive(p), p)
    end
  end)

  it("summarizes recurring line shapes", function()
    local lines = {}
    for i = 1, 5 do
      lines[#lines + 1] = ("2026/09/18 10:00:0%d [error] %d#0: upstream timed out"):format(i, i)
    end
    lines[#lines + 1] = "something else"
    local pats = context.line_patterns(lines)
    assert.is_truthy(pats[1]:match("^%s*5x%s+L1%-L5%s+"))
    assert.is_truthy(pats[1]:find("upstream timed out", 1, true))
  end)

  describe("related files", function()
    local dir, cwd

    before_each(function()
      cwd = vim.fn.getcwd()
      dir = vim.fn.tempname()
      vim.fn.mkdir(dir .. "/conf", "p")
      vim.fn.mkdir(dir .. "/app", "p")
      vim.fn.writefile({ "http {}" }, dir .. "/conf/nginx.conf")
      vim.fn.writefile({ "FROM alpine" }, dir .. "/app/Dockerfile")
      vim.fn.writefile({ "SECRET=1" }, dir .. "/.env")
      vim.fn.writefile({
        "services:",
        "  web:",
        "    build: ./app",
        "    env_file: .env",
        "    volumes:",
        "      - ./conf/nginx.conf:/etc/nginx/nginx.conf:ro",
        "      - /etc/passwd:/x:ro",
      }, dir .. "/compose.yaml")
      vim.cmd.cd(dir)
    end)

    after_each(function()
      vim.cmd.cd(cwd)
      vim.fn.delete(dir, "rf")
    end)

    it("includes referenced files but never secrets or absolute paths", function()
      vim.cmd.edit(dir .. "/compose.yaml")
      local out = context.related_files(vim.api.nvim_get_current_buf())
      assert.is_truthy(out:find('path="conf/nginx.conf"', 1, true))
      assert.is_truthy(out:find('path="app/Dockerfile"', 1, true))
      assert.is_falsy(out:find("SECRET", 1, true))
      assert.is_falsy(out:find("/etc/passwd", 1, true))
      vim.cmd("bwipeout!")
    end)
  end)
end)
