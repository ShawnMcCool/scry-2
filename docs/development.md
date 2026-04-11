# Development Guide

## Build & Run

```bash
mix setup              # install deps, create DB, run migrations, build assets
mix phx.server         # start dev server (http://localhost:4002)
mix test               # run tests
mix precommit          # compile --warning-as-errors, unlock unused deps, format, test
```

### Dev service (systemd)

```bash
scripts/install-dev    # install systemd user service

systemctl --user start scry-2-dev     # start
systemctl --user stop scry-2-dev      # stop
journalctl --user -u scry-2-dev -f    # logs
iex --name repl@127.0.0.1 --remsh scry_2_dev@127.0.0.1   # REPL
```

Disconnect the REPL with `Ctrl+\` (leaves the server running).

---

## Release & Tagging

### Local build verification

Before tagging, verify the release builds on your machine:

```bash
scripts/release    # build prod Elixir release + tray binary
                   # stages everything in _build/prod/package/
```

This runs `MIX_ENV=prod mix assets.deploy`, `mix release`, and `go build` for the tray binary.

### Local install

```bash
scripts/install    # scripts/release + installs the staged package locally
```

Use this to smoke-test the production binary against your real `Player.log`
before publishing, or to keep the production app installed alongside your
dev checkout for your own gameplay analysis.

Platform-specific package installers live at `scripts/install-linux` and
`scripts/install-macos`. Those are templates that get copied into the
release package by `scripts/release` — they expect the tray binary to be
a sibling and aren't meant to be run from the repo root. Use
`scripts/install` for developer-local installs.

### Tagging and publishing

```bash
scripts/tag-release 0.2.0
```

This script does the following in sequence:

1. Runs `mix precommit` — must pass cleanly (zero warnings, format, tests)
2. Aborts if the working copy has uncommitted changes after precommit (e.g. `mix format` rewrote files — commit them first)
3. Bumps `version:` in `mix.exs` to the given version
4. Describes the current jj change as `chore: release vX.Y.Z`
5. Creates a jj tag `vX.Y.Z` at the current revision
6. Pushes the `main` bookmark and the tag to GitHub
7. GitHub Actions builds Linux, macOS, and Windows archives and publishes them to GitHub Releases

The CI build is authoritative for multi-platform releases. `scripts/release` and `scripts/install` are local-only.

### Typical release workflow

```bash
# 1. Verify everything builds locally
scripts/release

# 2. Optionally smoke-test the local install
scripts/install

# 3. Tag and publish
scripts/tag-release 0.2.0
```

If `mix precommit` fails or the working copy is dirty after it runs, fix the issues, commit them (using `jj desc` + `jj new`), and re-run `scripts/tag-release`.

### Running dev and prod simultaneously

Dev uses port 4002. Add to `~/.config/scry_2/config.toml` to run both:

```toml
[server]
port = 4003
```

Each instance has its own independent database — no shared state.
