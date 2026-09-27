-- :checkhealth transplit
local M = {}

local function exe(name, why, required)
  if vim.fn.executable(name) == 1 then
    vim.health.ok(("`%s` found (%s)"):format(name, why))
  elseif required then
    vim.health.error(("`%s` not found (%s)"):format(name, why))
  else
    vim.health.info(("`%s` not found (optional: %s)"):format(name, why))
  end
end

function M.check()
  local config = require("transplit.config")
  local llm = require("transplit.llm")

  vim.health.start("transplit: core")
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 is required (vim.system, vim.uv)")
  end
  vim.health.info(("target language: %s, UI: %s"):format(config.options.target, config.lang()))

  vim.health.start("transplit: LLM backend")
  local backend = llm.backend()
  if backend == "api" then
    if vim.env.ANTHROPIC_API_KEY then
      vim.health.ok("Anthropic API via curl ($ANTHROPIC_API_KEY is set)")
    else
      vim.health.error("backend = 'api' but $ANTHROPIC_API_KEY is not set")
    end
    exe("curl", "API requests", true)
  else
    exe(config.options.cli, "Claude Code CLI backend", true)
    if not vim.env.ANTHROPIC_API_KEY then
      vim.health.info("set $ANTHROPIC_API_KEY to use the API directly (faster than starting the CLI per request)")
    end
  end

  vim.health.start("transplit: visualization")
  exe("d2", "diagram compilation and text rendering", false)
  exe("emacsclient", "SVG view in Emacs (ge)", false)
  if config.options.visual.open_cmd then
    exe(config.options.visual.open_cmd[1], "browser view (gb)", false)
  else
    exe("firefox", "browser view (gb); falls back to vim.ui.open", false)
  end

  vim.health.start("transplit: packet captures")
  if vim.fn.executable("tcpdump") == 1 or vim.fn.executable("tshark") == 1 then
    vim.health.ok("tcpdump/tshark found (.pcap files are decoded before explaining)")
  else
    vim.health.info("tcpdump/tshark not found (optional: decode .pcap files)")
  end
end

return M
