-- LLM backend: the Anthropic Messages API via curl, or the `claude` CLI.
local config = require("transplit.config")

local M = {}

---@type table<string, vim.SystemObj>
local running = {}

---"api" or "cli", resolving "auto".
function M.backend()
  local b = config.options.backend
  if b == "api" or b == "cli" then
    return b
  end
  return (vim.env.ANTHROPIC_API_KEY and vim.fn.executable("curl") == 1) and "api" or "cli"
end

---Text of a streamed delta line, for both the API's SSE and the CLI's stream-json.
---@return string?
function M.delta_text(line)
  local ok, obj = pcall(vim.json.decode, (line:gsub("^data: ", "")))
  if not ok or type(obj) ~= "table" then
    return nil
  end
  local ev = obj.type == "stream_event" and obj.event or obj
  if type(ev) == "table" and ev.type == "content_block_delta" and type(ev.delta) == "table" then
    if ev.delta.type == "text_delta" then
      return ev.delta.text
    end
  end
end

local function command(kind, system, user, stream)
  local o = config.options
  local mcfg = o[kind]
  if M.backend() == "api" then
    local body = vim.json.encode({
      model = mcfg.api_model,
      max_tokens = mcfg.max_tokens,
      stream = stream,
      system = system,
      messages = { { role = "user", content = user } },
    })
    return {
      "curl",
      "-sS",
      "-N",
      "https://api.anthropic.com/v1/messages",
      "-H",
      "x-api-key: " .. vim.env.ANTHROPIC_API_KEY,
      "-H",
      "anthropic-version: 2023-06-01",
      "-H",
      "content-type: application/json",
      "--data-binary",
      "@-",
    },
      body
  end
  -- no tools, no MCP servers, no settings/CLAUDE.md, no session file: halves startup time
  local cmd = {
    o.cli,
    "-p",
    "--model",
    mcfg.cli_model,
    "--tools",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
    "--setting-sources=",
    "--system-prompt",
    system,
  }
  if stream then
    vim.list_extend(cmd, { "--output-format", "stream-json", "--verbose", "--include-partial-messages" })
  end
  return cmd, user
end

---@class transplit.LlmRequest
---@field kind "translate"|"explain"|"visual"
---@field system string
---@field user string
---@field on_delta? fun(text: string) stream the answer; called on the main loop

---@param req transplit.LlmRequest
---@param cb fun(text: string?, err: string?) called on the main loop; err is "cancelled" when replaced
function M.request(req, cb)
  local stream = req.on_delta ~= nil
  local api = M.backend() == "api"
  local cmd, stdin = command(req.kind, req.system, req.user, stream)

  local acc, pending = {}, ""
  local function on_stdout(_, data)
    if not data then
      return
    end
    pending = pending .. data
    for line in pending:gmatch("([^\n]*)\n") do
      local text = M.delta_text(line)
      if text then
        acc[#acc + 1] = text
        vim.schedule(function()
          req.on_delta(text)
        end)
      end
    end
    pending = pending:match("[^\n]*$")
  end

  -- a new explanation replaces the one still streaming
  if req.kind == "explain" and running.explain then
    running.explain:kill(15)
  end
  local obj
  obj = vim.system(cmd, {
    stdin = stdin,
    text = true,
    cwd = vim.fn.stdpath("cache"), -- keep project CLAUDE.md files out of the prompt
    env = { MAX_THINKING_TOKENS = "0" }, -- thinking made translation ~4x slower
    stdout = stream and on_stdout or nil,
  }, function(res)
    vim.schedule(function()
      if running[req.kind] == obj then
        running[req.kind] = nil
      end
      if res.signal == 15 then
        return cb(nil, "cancelled")
      end
      local text
      if stream then
        text = table.concat(acc)
      elseif api then
        local ok, body = pcall(vim.json.decode, res.stdout or "")
        text = ok and type(body) == "table" and body.content and body.content[1] and body.content[1].text
      else
        text = res.stdout
      end
      if res.code == 0 and text and text ~= "" then
        cb(text)
      else
        cb(nil, vim.trim((res.stderr or "") .. " " .. (res.stdout or "")):sub(1, 300))
      end
    end)
  end)
  running[req.kind] = obj
end

return M
