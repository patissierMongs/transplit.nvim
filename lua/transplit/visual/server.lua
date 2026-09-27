-- Minimal HTTP server on nvim's own event loop (libuv), bound to 127.0.0.1.
--
-- Every path starts with a random token, so other local pages and websites can neither
-- read documents nor trigger LLM calls through it. The server lives as long as nvim.
local M = {}

---@type uv.uv_tcp_t?
local server
M.port = nil
M.token = nil

function M.hex(n)
  return (vim.uv.random(n):gsub(".", function(c)
    return ("%02x"):format(c:byte())
  end))
end

---Parse a complete request out of `data`, or nil while more bytes are needed.
---@return {method: string, path: string, body: string}?
function M.parse_request(data)
  local he = data:find("\r\n\r\n", 1, true)
  if not he then
    return nil
  end
  local len = tonumber(data:match("\r\n[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
  if #data < he + 3 + len then
    return nil
  end
  local method, path = data:match("^(%u+) (%S+)")
  return { method = method or "", path = path or "", body = data:sub(he + 4, he + 3 + len) }
end

---@param handler fun(method: string, path: string, body: string): string, string, string status, content type, body
---@return boolean ok
function M.ensure(handler)
  if server then
    return true
  end
  local s = vim.uv.new_tcp()
  if not s or not s:bind("127.0.0.1", 0) then
    return false
  end
  s:listen(32, function(err)
    if err then
      return
    end
    local client = assert(vim.uv.new_tcp())
    s:accept(client)
    local data = ""
    client:read_start(function(rerr, chunk)
      if rerr or not chunk then
        return client:close()
      end
      data = data .. chunk
      local req = M.parse_request(data)
      if not req then
        return
      end
      client:read_stop()
      vim.schedule(function()
        local ok, status, ctype, resp = pcall(handler, req.method, req.path, req.body)
        if not ok then
          status, ctype, resp = "500 Internal Server Error", "text/plain", tostring(status)
        end
        if client:is_closing() then
          return
        end
        client:write(
          ("HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n%s"):format(
            status,
            ctype,
            #resp,
            resp
          ),
          function()
            client:close()
          end
        )
      end)
    end)
  end)
  server = s
  M.port = s:getsockname().port
  M.token = M.hex(16)
  return true
end

return M
