-- Test runtime: this plugin + plenary.nvim, nothing from the user's config.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

local plenary = vim.env.PLENARY_DIR
if not plenary or plenary == "" then
  for _, p in ipairs({
    root .. "/.deps/plenary.nvim",
    vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
  }) do
    if vim.fn.isdirectory(p) == 1 then
      plenary = p
      break
    end
  end
end
assert(plenary, "plenary.nvim not found: set $PLENARY_DIR or run `make deps`")

vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(plenary)
vim.cmd("runtime plugin/plenary.vim")
vim.o.swapfile = false
