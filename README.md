# Scry 2

**Your own private MTG Arena stats tracker — running quietly in your system tray.**

Scry 2 watches MTGA's log file on your own machine, parses every match and draft
as you play, and serves a personal analytics dashboard at `http://localhost:6015`.
Nothing leaves your computer. No accounts, no sign-up, no telemetry. Just the
history you'd keep yourself, if you had the time.

Inspired by [17lands.com](https://17lands.com), but self-hosted and
Constructed-first.

---

## What you get

- **Live match history.** Every ranked, Bo1, Bo3, and casual match you play, with
  the deck you brought, the format, your opponent's colors, and the result —
  written to your local database the moment the match ends. No imports, no
  uploads.
- **Rank climb charts.** Your Constructed and Limited ranks plotted over time, per
  season. See when you spiked, when you stalled, and when the algorithm decided
  you were Silver-shaped for three weeks.
- **Deck-level win rates.** Sliced by format, season, and play/draw. Every version
  of a deck tracked separately so you can actually compare the Tuesday build to
  the Friday build.
- **Per-card performance.** For every card you own: games drawn, games in opening
  hand, games won with it in your deck. Your own data, not the population's.
- **Draft history.** Every pick, every pack, plus the deck you actually submitted.
  Re-read your drafts like replays.
- **Card browser.** Full MTGA card database, searchable and filterable. Card
  images are fetched from Scryfall on demand and cached locally.
- **Collection snapshot.** A read of your current MTGA card collection, refreshed
  automatically whenever you launch the game.
- **One-click updates.** When a new release ships, the app downloads and verifies
  it in-place. A progress modal shows each step; you can cancel mid-download.

---

## Platform support

| Platform | Status | Notes |
|---|---|---|
| **Linux** (x86_64, glibc) | **Primary** — fully supported and actively developed | Ubuntu / Arch / Fedora / any mainstream distro with `glibc` |
| **Windows** 10 / 11 (x86_64) | **Experimental** | MSI installer works; some edge cases still being smoothed. Use at your own pace. |
| **macOS** (Apple Silicon) | **Planned, not yet supported** | Release archives are produced but the installer story isn't ready. If you're excited about macOS, star the repo and check back. |

Scry 2 runs MTGA through Steam/Proton on Linux. No native Linux MTGA build
exists, but Proton handles it transparently — the watcher just reads the
`Player.log` that Proton writes.

---

## Before you install

Scry 2 needs MTGA's **Detailed Logs** setting enabled. This is MTGA's built-in
debug-event stream; without it, the log file only contains plain-text entries
and there's nothing to parse.

In MTGA:

1. Open **Options → View Account**
2. Enable **Detailed Logs (Plugin Support)**
3. Restart MTGA if it was already running

Scry 2 will warn you on its dashboard if it notices Detailed Logs is off.

---

## Install

### Linux — one command

```sh
curl -fsSL https://raw.githubusercontent.com/ShawnMcCool/scry-2/main/installer/install.sh | sh
```

That's it. The script resolves the latest release, verifies the download
against its published SHA-256 checksum, and hands off to the bundled
installer. Autostart is wired up via XDG, the tray icon appears, and the
dashboard becomes available at `http://localhost:6015`.

Want a specific version? `… | sh -s -- --version v0.20.0`.

> **GNOME users:** install the AppIndicator extension if the tray icon
> doesn't appear. Most other desktops show it out of the box.

### Windows — experimental

Download **`Scry2Setup-*.exe`** from the
[Releases page](../../releases/latest) and run it. The bundled Burn
installer handles the MSI and the Visual C++ Redistributable. Scry 2
will start on login and surface its tray icon.

> **Firewall:** on first launch Windows may prompt to allow
> **epmd** and **erlang** through — these are components of the bundled
> runtime. Allow both.

The Windows build is newer and less battle-tested than the Linux build.
If something breaks, the "Report to developer" button in
**Settings → Operations** opens a pre-filled GitHub issue with a
scrubbed error log. That's by far the fastest way to get it fixed.

### macOS — coming later

Release archives are produced on every version bump but the macOS
installer experience (LaunchAgent, first-run prompts, code signing)
isn't finished yet. There's no shell installer and no DMG. Track
progress on the repo; this section will become actionable when the work
lands.

---

## Using Scry 2

After install, open `http://localhost:6015`. The tray menu has an
**Open** shortcut that does the same thing.

- **Matches** — your game history, filterable by format, season, and deck.
  Click any match for a full play-by-play.
- **Decks** — one row per deck you've registered in MTGA. Win rate,
  games played, and version history.
- **Drafts** — every draft you've done, pick by pick.
- **Cards** — the full MTGA card database. Your own per-card stats are
  overlaid on each card.
- **Player** — global summary: total matches, overall win rate, most-played
  deck, longest streak.
- **Ranks** — rank timeline with a chart per format per season.
- **Economy** — gem/gold/wildcard history inferred from log events.
- **Collection** — auto-refreshed snapshot of your MTGA collection.
- **Settings** (gear icon, top right) — three tabs:
  - **System** — health checks, log watcher status, app version,
    one-click "Apply update" when a new release is out.
  - **Operations** — backend restart/stop, projection rebuilds,
    error export.
  - **Settings** — MTGA paths, 17lands refresh schedule, advanced config.

---

## Updates

Scry 2 checks GitHub for new releases once an hour and shows a badge on
**Settings → System** when one is available. Click **Apply update** and
the app will:

1. Download the new archive.
2. Verify it against the published SHA-256 checksum (refuses to install
   on mismatch).
3. Extract, hand off to the installer, and restart itself.

A progress modal shows each phase. You can cancel any time before the
installer is actually spawned.

If an update ever fails, the running install is untouched — Scry 2 is
conservative about that. Re-running the shell installer at any time is
always safe and also preserves your data.

---

## Your data

Scry 2 writes everything to a local SQLite database. Nothing is uploaded
anywhere. The database is yours to keep, move, back up, inspect, or
delete.

| Platform | Database location |
|---|---|
| Linux   | `~/.local/share/scry_2/scry_2.db` |
| Windows | `%APPDATA%\scry_2\scry_2.db` |
| macOS   | `~/Library/Application Support/scry_2/scry_2.db` *(location reserved; installer TBD)* |

Config lives alongside the database at `~/.config/scry_2/config.toml`
(Linux) or `%APPDATA%\scry_2\config.toml` (Windows), but most settings
are editable from the UI — you shouldn't need to touch these files.

---

## Uninstall

Scry 2's uninstaller removes the application binaries and the autostart
entry. **It never touches your database.** Uninstall, then decide
separately what to do with your history.

- **Linux:**   `~/.local/lib/scry_2/uninstall`
- **Windows:** `%LOCALAPPDATA%\scry_2\uninstall.bat`
- **macOS:**   `~/.local/lib/scry_2/uninstall` *(once supported)*

After uninstalling, the script prints the path + size of your database so
you can decide whether to keep it. To remove everything including
history, delete the database directory (shown above) by hand.

---

## Getting help

- Something parsed wrong? **Settings → Operations → Report to developer**
  opens a pre-filled GitHub issue with a scrubbed error log.
- Feature idea or bug not tied to a specific event?
  [Open an issue](../../issues) directly.

---

## Acknowledgements

Scry 2 stands on other people's generous work.

- **[Beleren](https://www.delvefonts.com)** by Delve Fonts — the official
  MTG card-title typeface, commissioned by Wizards of the Coast. Used for
  headings. Proprietary; used here under Wizards'
  [Fan Content Policy](https://company.wizards.com/en/legal/fancontentpolicy).
- **MPlantin** — the MTG rules-and-flavor-text typeface, derived from the
  Plantin family. Used for card text rendering. Proprietary to Wizards of
  the Coast.
- **[Mana font](https://github.com/andrewgioia/mana)** by Andrew Gioia —
  the mana, set, and loyalty symbols. Licensed under SIL OFL 1.1 (font)
  and MIT (CSS).
- **[17lands](https://17lands.com)** — for the public card reference
  datasets that make card-aware analytics possible without scraping, and
  for setting the standard on what self-service MTGA stats should feel
  like. Card data is licensed
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/).
- **[Scryfall](https://scryfall.com)** — for the card image API that
  powers Scry 2's card browser. Please respect their
  [rate limits and guidelines](https://scryfall.com/docs/api) if you fork
  this project.
- **[Wizards of the Coast](https://magic.wizards.com)** — Magic: The
  Gathering, MTG Arena, mana symbols, set symbols, and all card text and
  imagery are property of Wizards of the Coast LLC. Scry 2 is an
  independent, unofficial tool and is not affiliated with, endorsed, or
  sponsored by Wizards of the Coast. See Wizards'
  [Fan Content Policy](https://company.wizards.com/en/legal/fancontentpolicy)
  for how fan projects like this one are permitted to exist.
- **The Elixir and Phoenix communities** — for building a stack where a
  single-developer project can credibly take on real-time ingestion,
  event sourcing, and a live admin UI without a team behind it.

---

## License

Scry 2 itself is licensed under the MIT License — see [LICENSE](LICENSE).

Third-party assets retain their original licenses as noted above.

---

Contributing or building from source? See [DEVELOPMENT.md](DEVELOPMENT.md).
