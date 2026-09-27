# make test    run the test suite (plenary.nvim busted) in a clean Neovim
# make lint    check formatting with stylua
# make demo    re-record the README GIFs (real LLM calls; needs d2 and a backend)
# make deps    fetch plenary.nvim into .deps/ (CI, or when it isn't installed via lazy.nvim)
NVIM ?= nvim
PLENARY_DIR ?= $(if $(wildcard .deps/plenary.nvim),.deps/plenary.nvim,)

.PHONY: test lint format deps demo

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

AGG ?= $(if $(wildcard .deps/agg),.deps/agg,agg)
AGG_FLAGS = --font-family "JetBrainsMono Nerd Font Mono,D2KodingLigature Nerd Font Mono" \
	--font-size 14 --theme monokai --idle-time-limit 1.5 --fps-cap 15

demo:
	python3 docs/demo/record.py translate explain visualize
	for n in translate explain visualize; do $(AGG) $(AGG_FLAGS) docs/demo/$$n.cast docs/demo/$$n.gif; done
