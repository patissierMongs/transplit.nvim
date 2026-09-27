-- On-disk cache: template translations and per-file profiles, both keyed by file.
local config = require("transplit.config")

local M = {}

---@type {tr: table<string,string>, profile: table<string,string>}?
local data

local function load()
  if data then
    return data
  end
  data = { tr = {}, profile = {} }
  local f = io.open(config.options.cache_file, "r")
  if f then
    local ok, decoded = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(decoded) == "table" then
      data.tr = type(decoded.tr) == "table" and decoded.tr or {}
      data.profile = type(decoded.profile) == "table" and decoded.profile or {}
    end
  end
  return data
end

function M.save()
  local file = config.options.cache_file
  vim.fn.mkdir(vim.fn.fnamemodify(file, ":h"), "p")
  local f = io.open(file, "w")
  if f then
    f:write(vim.json.encode(load()))
    f:close()
  end
end

local function tr_key(key, tmpl)
  return key .. "\0" .. tmpl
end

function M.get_translation(key, tmpl)
  return load().tr[tr_key(key, tmpl)]
end

function M.set_translation(key, tmpl, text)
  load().tr[tr_key(key, tmpl)] = text
end

function M.get_profile(key)
  return load().profile[key]
end

function M.set_profile(key, profile)
  load().profile[key] = profile
end

---@param key? string clear one file, or everything when nil
function M.clear(key)
  local d = load()
  if not key then
    d.tr, d.profile = {}, {}
  else
    d.profile[key] = nil
    for k in pairs(d.tr) do
      if vim.startswith(k, key .. "\0") then
        d.tr[k] = nil
      end
    end
  end
  M.save()
end

---Forget the in-memory copy (tests, or after changing `cache_file`).
function M.reset()
  data = nil
end

return M
