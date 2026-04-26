# Changelog

User-facing release notes for Scry2. Internal refactors, test changes,
and dependency bumps with no user impact are omitted here — see the git
history for the full engineering trail.

This file is the source of truth for the GitHub release body and the
in-app **What's new in vX.Y.Z** disclosure on Settings → Updates. Add
new entries under `## [Unreleased]

## v0.25.2 — 2026-04-26` as you work; `scripts/tag-release`
renames that section on tag and the release workflow extracts it.

## [Unreleased]

## v0.25.1 — 2026-04-26

### Fixed

- **Auto-update no longer leaves the app stopped.** After applying an
  update, the running release's environment was leaking into the new
  installer — pointing the freshly relaunched tray at a release
  directory that had just been deleted. The backend would die in its
  startup wrapper, and the watchdog would respawn zombie after zombie
  while the UI stayed unreachable until you restarted it manually.
  The installer now runs with a clean environment, so the new release
  starts cleanly the moment the apply finishes.

## v0.25.0 — 2026-04-25

### New

- **See what's new before you update.** Settings → Updates now has a
  *What's new in vX.Y.Z* disclosure under the **Apply update** button.
  Expand it to read the curated release notes for the version you're
  about to install — headings, bullets, bold, inline code, the lot —
  without round-tripping to GitHub. The notes render in a contained,
  scrollable panel so longer changelogs stay tidy.

## v0.24.2 — 2026-04-25

Maintenance release — no user-visible changes. Internal cleanup of the
collection-diagnostics LiveView (logic extracted to a helper module per
ADR-013) and a Rust type-alias to silence a clippy warning in the
collection reader NIF.
