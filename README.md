# Scry2

**A self-hosted Magic: The Gathering Arena stats tracker.** Scry2 quietly
watches your MTGA `Player.log` file, parses every match and draft as it
happens, and serves a personal analytics dashboard at
`http://localhost:6015`.

Your data is yours. Nothing leaves your machine. No accounts, no cloud, no
telemetry — just a small Elixir/Phoenix app sitting in your system tray,
turning MTGA's raw event stream into history you can actually learn from.

Inspired by [17lands.com](https://17lands.com), but self-hosted and
Constructed-first.

## Features

- **Real-time ingestion** — stats update the moment a match ends, no manual
  imports or uploads
- **Match history** — full play-by-play with deck, format, opponent, and
  result; win rates sliced by deck, format, and Limited season
- **Draft tracking** — every pick, every pack, plus the deck you actually
  submitted at the end of the draft
- **Card performance** — per-card win rate, games drawn, games in opening
  hand, and mulligan stats across your own play history
- **Rank climb charts** — season-scoped rank progression over time, for both
  Constructed and Limited queues
- **Card browser** — searchable card database with images auto-downloaded
  from Scryfall on demand
- **Complete card coverage** — automatic refresh from 17lands' public card
  datasets, with MTGA client data import for card identity fallback
- **Event-sourced architecture** — every raw MTGA event is persisted before
  any downstream processing, so projections can always be rebuilt from the
  log of record
- **Zero-config install** — the Elixir runtime is bundled; no BEAM, no
  dependencies, no database server to set up
- **Automatic updates** — the app checks GitHub Releases hourly and offers
  one-click apply from the **Settings → Updates** page; archives are
  SHA256-verified before install

---

## Requirements

- Magic: The Gathering Arena with **Detailed Logs** enabled
- One of:
  - Windows 10+ (x86_64)
  - macOS 12+ (Apple Silicon)
  - Linux (x86_64, glibc — musl/Alpine not supported)
- No other software needed — the runtime is bundled

### Enable Detailed Logs in MTGA

In MTGA: **Options → View Account → Detailed Logs (Plugin Support)**

Without this, Scry2 cannot parse your game data.

---

## Install

### Linux or macOS

One command, end-to-end:

```sh
curl -fsSL https://raw.githubusercontent.com/ShawnMcCool/scry-2/main/installer/install.sh | sh
```

The bootstrap script resolves the latest release, verifies the archive
against its published SHA256 checksum, and hands off to the bundled
installer. Autostart is wired up automatically (XDG on Linux,
LaunchAgent on macOS). To pin a specific version, append
`-s -- --version v0.18.0` to the `sh` invocation.

### Windows

Download **`Scry2Setup-*.exe`** from the
[Releases page](../../releases/latest) and run it. The bundled Burn
installer takes care of the MSI and the Visual C++ Redistributable.

> **Firewall:** on first launch, Windows may ask you to allow
> **epmd** and **erlang** through the firewall. These are components of the
> bundled runtime — allow both for Scry2 to function.

### Manual install (any platform)

Prefer to inspect or unpack the archive yourself?

1. Download the release for your platform from the
   [Releases page](../../releases/latest).
2. Extract the archive.
3. Run the bundled installer:
   - **Linux / macOS:** `./install`
   - **Windows (zip path):** double-click `install.bat`

Scry2 starts automatically on each login and is accessible at
`http://localhost:6015`.

### Keeping up to date

Once installed, future updates are one-click from
**Settings → System → Apply update**. The app checks GitHub Releases
hourly and downloads + verifies the archive before installing.
No need to re-run the bootstrap.

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

The uninstall script is copied into the install directory during installation,
so you don't need to keep the original release archive around.

- **Windows:** `%LOCALAPPDATA%\scry_2\uninstall.bat`
- **macOS:**   `~/.local/lib/scry_2/uninstall`
- **Linux:**   `~/.local/lib/scry_2/uninstall`

You can also run `uninstall` / `uninstall.bat` directly from the extracted
release archive if you still have it.

**Your database is never deleted by the uninstall script.** The script removes
only the application binaries and the autostart entry. It then prints the
path and size of your database so you can decide what to do with it.

Database locations:

| Platform | Path |
|---|---|
| Linux   | `~/.local/share/scry_2/scry_2.db` |
| macOS   | `~/Library/Application Support/scry_2/scry_2.db` |
| Windows | `%APPDATA%\scry_2\scry_2.db` |

To remove everything including your history, delete the directory containing
your database after uninstalling. The uninstall script prints the exact
command to run.

---

## Acknowledgements

Scry2 is built on the work of a lot of generous people.

- **[Beleren](https://www.delvefonts.com)** by Delve Fonts — the official
  MTG card title typeface, commissioned by Wizards of the Coast. Used for
  headings and display text. Proprietary; used here under Wizards'
  [Fan Content Policy](https://company.wizards.com/en/legal/fancontentpolicy).
- **MPlantin** — the MTG rules and flavor text typeface, derived from the
  Plantin family. Used for card text rendering. Proprietary to Wizards of
  the Coast; community-distributed for fan tools under the same Fan Content
  Policy.
- **[Mana font](https://github.com/andrewgioia/mana)** by Andrew Gioia —
  the mana symbols, set icons, and loyalty badges that make MTG content
  recognizable on the web. Licensed under SIL OFL 1.1 (font) and MIT (CSS).
  If you ever need to render Magic symbols in your own project, start there.
- **[17lands](https://17lands.com)** — for the public card reference
  datasets that make card-aware analytics possible without scraping, and for
  setting the standard on what self-service MTGA stats should feel like.
  Card data is licensed
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- **[Scryfall](https://scryfall.com)** — for the card image API that
  powers Scry2's card browser. Please respect their
  [rate limits and guidelines](https://scryfall.com/docs/api) if you fork
  this project.
- **[Wizards of the Coast](https://magic.wizards.com)** — Magic: The
  Gathering, MTG Arena, mana symbols, set symbols, and all card text and
  imagery are property of Wizards of the Coast LLC. Scry2 is an independent,
  unofficial tool and is not affiliated with, endorsed, or sponsored by
  Wizards of the Coast. See Wizards'
  [Fan Content Policy](https://company.wizards.com/en/legal/fancontentpolicy)
  for how fan projects like this one are permitted to exist.
- **The Elixir and Phoenix communities** — for building a stack where a
  single-developer project can credibly take on real-time ingestion,
  event sourcing, and a live admin UI without a team behind it.

## License

Scry2 itself is licensed under the MIT License — see [LICENSE](LICENSE).

Third-party assets retain their original licenses as noted above.

---

Contributing or building from source? See [DEVELOPMENT.md](DEVELOPMENT.md).
