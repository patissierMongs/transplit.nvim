# Demo recordings

The GIFs in the main README are recorded by a script, not by hand:

- `record.py` runs Neovim in a pseudo-terminal (170×34), types the keys of each scenario and
  writes an [asciicast v2](https://docs.asciinema.org/manual/asciicast/v2/) file. Waits for the
  LLM are done by asking Neovim over its `--listen` socket (e.g. "is any winbar still showing ⏳?").
- The data in `data/` is synthetic (documentation IP range `203.0.113.0/24`, `example.com`). It is
  copied into a server-like layout (`var/log/nginx`, `srv/stack`) in a temp directory first, so
  the model sees realistic paths.
- [agg](https://github.com/asciinema/agg) renders the `.cast` files to GIF with idle time capped
  at 1.5 s, so the LLM wait is shortened but everything shown is real output.

```bash
make demo        # re-record all three (real LLM calls; needs d2 and a working backend)
```

The recordings use the author's Neovim config (LazyVim, tokyonight); yours will look different.
