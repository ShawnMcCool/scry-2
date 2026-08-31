# Scry 2

A local match, draft, and collection tracker for Magic: The Gathering Arena.

Scry 2 reads the `Player.log` file that MTGA writes on your machine, records
each match and draft as it finishes, and serves a dashboard at
`http://localhost:6015`. Your game data stays in a SQLite database on your
disk. There are no accounts and no upload.

It is inspired by [17lands](https://17lands.com), but it is self-hosted and
tracks one player, across both Constructed and Limited.

**Linux only.** A Windows build exists and installs, but it is experimental
and lacks the collection features. macOS is not supported. See
[Platform support](#platform-support).

---

## Features

### Play

- **Matches** — every match, with the deck you played, the format, the
  opponent's colours, the result, and (for Standard) a label for the
  opponent's archetype. Summary stats: matches, win rate, average turns,
  average mulligans.
- **Decks** — one entry per deck in MTGA, with win rate, games played,
  Best-of-1 and Best-of-3 split, and a history of every version you saved.
  Per deck: hand profile and keep rate, per-card win rate and impact, and
  on-the-play versus on-the-draw results.
- **Drafts** — every pick in every pack, and the deck you submitted.
- **NetDecks** — Standard decklists fetched daily from MTGO tournament
  results, grouped by archetype and scored against your collection:
  buildable now, craftable with your wildcards, or short. Each list has an
  MTGA import string. Scoring requires the collection reader (Linux only);
  without it, lists show without ownership information.

### Profile

- **Player** — matches, record, win rate, average turns, current streak.
- **Ranks** — rank over time, one chart per format, selectable by season.
- **Home** — a small set of observations computed from your own data
  (Bo1 versus Bo3 gap, on-play versus on-draw, mulligan outcomes, rank
  milestones, deck colour outliers, and similar). The wording is fixed per
  observation; only the numbers come from your data.

### Economy

- **Economy** — gold, gems, wildcards, and vault progress, with the event
  entries and inventory changes they came from.
- **Wildcard crafts** — which cards each wildcard spend went to, derived
  from collection snapshots (Linux only).

### Collection

- **Collection** — a snapshot of your MTGA collection, read from the running
  MTGA process's memory, refreshed automatically when log activity shows the
  game is running. Set completion per set. The reader can be turned off in
  Settings. Linux only.

### Cards

- **Cards** — the MTGA card database, searchable. Card data comes from your
  local MTGA install joined with Scryfall bulk data; images come from
  Scryfall on demand and are cached on disk.

### Maintenance

- **Updates** — an hourly check against GitHub Releases. Applying an update
  downloads the archive, verifies it against the published SHA-256 sum,
  and hands off to the bundled installer. You can cancel before the
  installer starts.
- **Operations** — rebuild any projection from the stored event log,
  re-ingest the log, export errors, and open a pre-filled GitHub issue.
  Nothing is sent to GitHub until you confirm in your browser.
- **Console** — a filterable view of the app's own log output.

---

## Platform support

| Platform | Status | What works |
|---|---|---|
| **Linux** x86_64, glibc, systemd | Supported | Everything above |
| **Windows** 10 / 11 x86_64 | Experimental | Matches, decks, drafts, ranks, economy, cards, updates. Collection reading is not implemented on Windows, so Collection, wildcard crafts, and NetDecks ownership scoring are absent |
| **macOS** Apple Silicon | Not supported | CI produces an archive, but there is no installer, autostart, or first-run path. Do not use it |

MTGA has no native Linux build. Scry 2 finds `Player.log` under Steam
(native or Flatpak) with Proton, and under Lutris. Any other Wine prefix
can be set by hand in Settings or during first-run setup.

Linux needs a musl-free (glibc) distribution and a systemd user session.
Alpine and other musl distributions are not supported.

---

## Before you install

Scry 2 needs MTGA's **Detailed Logs** setting. Without it, `Player.log`
contains only plain-text lines and there is nothing to parse.

In MTGA:

1. Open **Options → View Account**.
2. Enable **Detailed Logs (Plugin Support)**.
3. Restart MTGA if it was already running.

The dashboard warns you if Detailed Logs is off.

---

## Install

### Linux

```sh
curl -fsSL https://raw.githubusercontent.com/ShawnMcCool/scry-2/main/installer/install.sh | sh
```

The script resolves the latest release, downloads the Linux archive,
verifies it against the published SHA-256 sum, and runs the bundled
installer. The installer:

- copies the release to `~/.local/lib/scry_2`
- installs and starts the systemd user service `scry-2`
- enables lingering so the service keeps running after you log out
- adds a **Scry 2** entry to your application menu that opens
  `http://localhost:6015`

There is no tray icon on Linux. The service is controlled with systemd:

```sh
systemctl --user status scry-2
systemctl --user stop scry-2
systemctl --user start scry-2
journalctl --user -u scry-2 -f
```

To install a specific version: `… | sh -s -- --version v0.20.0`.

The first time you open the dashboard, a setup page checks that
`Player.log` was found and that events are arriving, and lets you set
the path by hand if detection failed.

### Windows (experimental)

1. Download `Scry2-<version>.msi` from the
   [Releases page](../../releases/latest).
2. Run it. It installs to `C:\Program Files\Scry2`, adds Windows Firewall
   rules for the bundled Erlang runtime (`epmd.exe` and `erl.exe`), and
   registers the tray program to start on login.
3. The tray icon's menu has **Open**, **Open Settings**, **Auto-start on
   login**, and **Quit**. The tray starts and stops the backend and
   restarts it if it crashes.

In-app updates on Windows do not update the MSI install. Applying an
update installs the new version to `%LOCALAPPDATA%\scry_2`, points the
login autostart at it, and starts it from there; the copy in
`C:\Program Files\Scry2` stays behind until you uninstall it from
**Settings → Apps**. Running a newer MSI later removes the
`%LOCALAPPDATA%` copy. This is a known defect of the experimental build.

The Windows build gets far less use than the Linux build. If something
breaks, **Operations → Report to developer** opens a pre-filled GitHub
issue with a scrubbed error log.

### macOS

Not supported. There is nothing to install.

---

## Uninstall

The uninstaller removes the program and its autostart entry. It does not
delete your database or config.

| Platform | Command |
|---|---|
| Linux | `~/.local/lib/scry_2/uninstall` |
| Windows, MSI install | **Settings → Apps → Scry 2 → Uninstall** |
| Windows, after an in-app update | `%LOCALAPPDATA%\scry_2\uninstall.bat` as well |

On Linux the uninstaller prints the database path and size, and the exact
`rm -rf` command that removes the database and config if you want them gone
too.

---

## Your data

Everything Scry 2 records is in one SQLite database. You can copy, back up,
inspect, or delete it.

| Platform | Database | Config |
|---|---|---|
| Linux | `~/.local/share/scry_2/scry_2.db` | `~/.config/scry_2/config.toml` |
| Windows | `%APPDATA%\scry_2\scry_2.db` | `%APPDATA%\scry_2\config.toml` |

The config file is optional; the settings it holds are also editable in the
UI. Card images are cached next to the database under `cache/`.

Scry 2 never writes to any MTGA file. It reads `Player.log`, the MTGA card
database in your MTGA install, and (on Linux) the running MTGA process's
memory for the collection snapshot.

### Network connections

Scry 2 makes these outbound requests. None of them carry your game data.

| Destination | When | Purpose |
|---|---|---|
| `api.github.com` | Hourly | Check for a new release |
| `github.com` | When you apply an update | Download the release archive and checksum file |
| `api.scryfall.com` | On card refresh (scheduled; interval in Settings) | Scryfall bulk card data |
| `api.scryfall.com` | When a card image is first shown | Card images, then cached |
| `github.com/Badaro/MTGOFormatData` | Daily | Archetype definitions for deck labels |
| `mtgo.com/decklists` | Daily | Tournament decklists for NetDecks |

**Report to developer** opens a pre-filled GitHub issue in your browser.
You see the contents before anything is submitted.

---

## Getting help

- Something parsed wrong or a page errored: **Operations → Report to
  developer**.
- Anything else: [open an issue](../../issues).

---

## Acknowledgements

- **[Beleren](https://www.delvefonts.com)** by Delve Fonts — the MTG
  card-title typeface, commissioned by Wizards of the Coast. Used for
  headings. Proprietary; used under Wizards'
  [Fan Content Policy](https://company.wizards.com/en/legal/fancontentpolicy).
- **MPlantin** — the MTG rules-text typeface. Used for card text.
  Proprietary to Wizards of the Coast.
- **[Mana](https://github.com/andrewgioia/mana)** and
  **[Keyrune](https://github.com/andrewgioia/keyrune)** by Andrew Gioia —
  mana, loyalty, and set symbols. SIL OFL 1.1 (fonts) and MIT (CSS).
- **[Scryfall](https://scryfall.com)** — bulk card data and card images,
  used under their [API terms](https://scryfall.com/docs/api). If you fork
  this project, keep within their rate limits.
- **[MTGOFormatData](https://github.com/Badaro/MTGOFormatData)** by Badaro —
  archetype definitions used to label decks.
- **[17lands](https://17lands.com)** — the model for what a personal MTGA
  tracker should show.
- **[Wizards of the Coast](https://magic.wizards.com)** — Magic: The
  Gathering, MTG Arena, mana and set symbols, and all card text and imagery
  are property of Wizards of the Coast LLC. Scry 2 is an independent,
  unofficial tool and is not affiliated with, endorsed, or sponsored by
  Wizards of the Coast. It exists under their
  [Fan Content Policy](https://company.wizards.com/en/legal/fancontentpolicy).

---

## License

MIT — see [LICENSE](LICENSE). Third-party assets keep their own licenses as
listed above.

To build from source or contribute, see [DEVELOPMENT.md](DEVELOPMENT.md).
