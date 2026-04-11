# Scry2

A self-hosted Magic: The Gathering Arena stats tracker. Scry2 watches your
`Player.log` file, parses match and draft events, and serves a rich analytics
dashboard at `http://localhost:6015`.

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
`http://localhost:6015`.

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

## Card Data Attribution

Card reference data is sourced from [17lands](https://17lands.com) public
datasets, licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).

---

## License

MIT — see [LICENSE](LICENSE).

---

Contributing or building from source? See [DEVELOPMENT.md](DEVELOPMENT.md).
