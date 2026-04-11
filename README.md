# Scry2

A self-hosted Magic: The Gathering Arena stats tracker. Scry2 watches your
`Player.log` file, parses match and draft events, and serves a rich analytics
dashboard at `http://localhost:4002`.

Inspired by [17lands.com](https://17lands.com). Built with Elixir/Phoenix.

- Real-time log watching — stats update as you play, no manual imports
- Match history with win rates by deck, format, and Limited season
- Draft pick history and deck submitted per draft
- Card performance charts — win rate and drawn/mulliganed stats per card
- Season-scoped climb charts showing rank progression over time
- Card image browser with auto-download from Scryfall
- Automatic card database refresh from 17lands public datasets
- MTGA client data import for complete card identity coverage
- Self-hosted — all data stays local, no accounts or internet dependency

---

## Requirements

- Magic: The Gathering Arena with **Detailed Logs** enabled
- Windows 10+, macOS 12+, or Linux (x86_64)
- No other software needed — the runtime is bundled

### Enable Detailed Logs in MTGA

In MTGA: **Options → View Account → Detailed Logs (Plugin Support)**

Without this, Scry2 cannot parse your game data.

---

## Install

1. Download the latest release for your platform from the
   [Releases page](../../releases/latest)
2. Extract the archive
3. Run the install script:
   - **Windows:** double-click `install.bat`
   - **macOS / Linux:** `./install` in a terminal

Scry2 will start automatically on each login and is accessible at
`http://localhost:4002`.

---

## Configuration

On first run, Scry2 creates a config file at:
- **Linux/macOS:** `~/.config/scry_2/config.toml`
- **Windows:** `%APPDATA%\scry_2\config.toml`

Most settings (Player.log path, card refresh schedule, etc.) are configurable
through the **Settings** page in the UI — no manual file editing needed.

If Scry2 can't find your `Player.log` automatically, set the path in
**Settings → Log File**.

---

## Uninstall

Run `uninstall` (or `uninstall.bat` on Windows) from the extracted archive.
Your data and config are preserved; delete `~/.local/share/scry_2/` (Linux),
`~/Library/Application Support/scry_2/` (macOS), or `%APPDATA%\scry_2\`
(Windows) to remove everything.

---

## Card Data Attribution

Card reference data is sourced from [17lands](https://17lands.com) public
datasets, licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

---

## License

MIT — see [LICENSE](LICENSE).

---

---

# Developer Guide

## Requirements

- Elixir 1.18+ and Erlang/OTP 27+
- [mise](https://mise.jdx.dev/) (recommended for toolchain management)

## Setup

```bash
mix setup          # install deps, create DB, build assets
mix phx.server     # start dev server at http://localhost:4002
mix test           # run tests
mix precommit      # compile --warnings-as-errors, format, test — run before committing
```

## Dev Service

Install a persistent systemd user service so the dev server survives terminal sessions:

```bash
scripts/install-dev                               # install and start the service
systemctl --user start scry-2-dev                 # start
systemctl --user stop scry-2-dev                  # stop
journalctl --user -u scry-2-dev -f                # logs
iex --name repl@127.0.0.1 --remsh scry_2_dev@127.0.0.1   # remote REPL
```

Disconnect the REPL with `Ctrl+\` (leaves the server running).

## Releasing

Releases are built automatically by GitHub Actions when a version tag is pushed.
Use the `scripts/tag-release` script to bump the version and trigger a release:

```bash
scripts/tag-release 0.2.0
```

This will:
1. Validate the version is semver
2. Bump `version:` in `mix.exs`
3. Describe the jj change as `chore: release v0.2.0`
4. Create a `v0.2.0` git tag
5. Push the bookmark and tag to the remote

GitHub Actions then builds Linux, macOS, and Windows release archives and
publishes them to the [Releases page](../../releases).

To build a release locally (without publishing):

```bash
MIX_ENV=prod mix assets.deploy && MIX_ENV=prod mix release
# output: _build/prod/rel/scry_2/
```

## Architecture

See `CLAUDE.md` for bounded context layout, data model, and architectural
decision records under `decisions/`.
