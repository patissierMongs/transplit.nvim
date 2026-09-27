-- transplit.nvim: context-aware LLM translation, explanation and visualization for
-- whatever you are reading in Neovim (logs, man pages, configs, code, command output).
local config = require("transplit.config")

local M = {}

---Toggle the side-by-side translation pane.
---@param whole? boolean keep going until the whole file is translated
function M.translate(whole)
  require("transplit.translate").toggle(whole)
end

---Explain lines [first, last] (default: the cursor line) with file context.
function M.explain(first, last)
  require("transplit.explain").lines(first, last)
end

---Explain the whole file.
function M.explain_file()
  require("transplit.explain").file()
end

---Visualize the file, focusing on [first, last] when given.
function M.visualize(first, last)
  require("transplit.visual").run(first, last)
end

---Retry translations that failed validation.
function M.retry()
  require("transplit.translate").retry()
end

---@param all? boolean clear everything instead of the current file
function M.clear_cache(all)
  local ui = require("transplit.ui")
  local key = not all and require("transplit.context").file_key(ui.source_buf()) or nil
  require("transplit.cache").clear(key)
end

local function range_args(o)
  if o.range > 0 then
    return o.line1, o.line2
  end
end

local function create_commands()
  local cmd = vim.api.nvim_create_user_command
  cmd("TransSplit", function(o)
    M.translate(o.bang)
  end, { bang = true, desc = "Toggle side-by-side translation (! = whole file)" })
  cmd("TransSplitRetry", M.retry, { desc = "Retry failed translations" })
  cmd("TransExplain", function(o)
    M.explain(range_args(o))
  end, { range = true, desc = "Explain the cursor line or range" })
  cmd("TransExplainFile", M.explain_file, { desc = "Explain the whole file" })
  cmd("TransVisual", function(o)
    M.visualize(range_args(o))
  end, { range = true, desc = "Visualize the file (or range) as diagrams" })
  cmd("TransVisualEmacs", function()
    require("transplit.visual").open_emacs()
  end, { desc = "Show the last visualization in Emacs" })
  cmd("TransVisualBrowser", function()
    require("transplit.visual").open_browser()
  end, { desc = "Show the last visualization in a browser" })
  cmd("TransClearCache", function(o)
    M.clear_cache(o.bang)
  end, { bang = true, desc = "Clear the cache for this file (! = all files)" })
end

local function set_keymaps(km)
  if not km then
    return
  end
  km = vim.tbl_extend("force", config.default_keymaps, type(km) == "table" and km or {})
  local function map(mode, lhs, rhs, desc)
    if lhs then
      vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
    end
  end
  map("n", km.translate, function()
    M.translate(false)
  end, "Translate page")
  map("n", km.translate_whole, function()
    M.translate(true)
  end, "Translate whole file")
  map("n", km.explain, function()
    M.explain()
  end, "Explain line")
  map("x", km.explain, ":TransExplain<cr>", "Explain selection")
  map("n", km.explain_file, M.explain_file, "Explain whole file")
  map("n", km.visualize, function()
    M.visualize()
  end, "Visualize file")
  map("x", km.visualize, ":TransVisual<cr>", "Visualize selection")
end

---@param opts? transplit.Config
function M.setup(opts)
  config.setup(opts)
  require("transplit.cache").reset()
  create_commands()
  set_keymaps(config.options.keymaps)
end

return M
