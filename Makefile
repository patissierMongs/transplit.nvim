# make test    run the test suite (plenary.nvim busted) in a clean Neovim
# make lint    check formatting with stylua
# make deps    fetch plenary.nvim into .deps/ (CI, or when it isn't installed via lazy.nvim)
NVIM ?= nvim
PLENARY_DIR ?= $(if $(wildcard .deps/plenary.nvim),.deps/plenary.nvim,)

.PHONY: test lint format deps

test:
	PLENARY_DIR=$(PLENARY_DIR) $(NVIM) --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/ { minimal_init = 'tests/minimal_init.lua', sequential = true }"

lint:
	stylua --check lua/ tests/

format:
	stylua lua/ tests/

deps:
	mkdir -p .deps
	test -d .deps/plenary.nvim || git clone --depth 1 https://github.com/nvim-lua/plenary.nvim .deps/plenary.nvim
