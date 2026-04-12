# Mana Icon Font for MTG Symbol Display

- Status: Accepted
- Date: 2026-04-10

## Context and Problem Statement

Mana color identity was displayed as colored letter text (e.g., bold "U" in sky-blue via `mana_pips/1`). This is readable but lacks the immediate visual recognition of the circular pip symbols that MTG players expect from every digital MTG tool. The Mana font library (andrewgioia/Mana) provides 300+ MTG symbols as an icon font under SIL OFL 1.1 / MIT licensing and is the community standard for web-based MTG tools.

Beyond color pips, the library covers card types, tap/untap, loyalty, double-faced card indicators, ability symbols (150+), counters (40+), guilds, clans, schools, and watermarks — a complete MTG iconographic vocabulary. We want zero friction to reach any symbol.

## Decision

Adopt the Mana icon font and establish a **universal component** (`mana_symbol/1`) that accepts any suffix code from the library verbatim — no enumeration, no mapping. Higher-level ergonomic helpers (`mana_pip/1`, `mana_pips/1`) are built on top of it for the common case of color identity display.

## Installation Policy

- **Vendor only** — no CDN, no npm. Files are pinned to a known-good state in the repo.
- **File locations:**
  - `assets/vendor/mana.css` — downloaded from `andrewgioia/Mana` GitHub, CSS MIT License
  - `priv/static/fonts/mana.woff2` — primary font, SIL OFL 1.1
  - `priv/static/fonts/mana.woff` — fallback font, SIL OFL 1.1
- **Font path rule:** The shipped `mana.css` uses relative paths (`../fonts/…`) that break after Tailwind compilation. After every update to `mana.css`, the `@font-face` src declarations **must** be changed to absolute paths:
  ```css
  src: url("/fonts/mana.woff2") format("woff2"),
       url("/fonts/mana.woff") format("woff");
  ```
- **MPlantin** — now vendored separately (see UIDR-009). The `mana.css` rules that reference it will resolve to the vendored MPlantin font files.
- **To update:** `curl -sLO https://raw.githubusercontent.com/andrewgioia/Mana/master/css/mana.css`, replace `@font-face` src, replace font files.

## Symbol Taxonomy

Complete reference so developers know what's available without consulting upstream docs:

| Category | Class pattern | Example codes | ~Count |
|---|---|---|---|
| Mana colors | `ms-{w\|u\|b\|r\|g\|c}` | `w`, `u`, `b`, `r`, `g`, `c` | 6 |
| Numeric costs | `ms-{0–20}` | `0`, `5`, `10`, `20` | 21 |
| Special costs | `ms-{code}` | `x`, `y`, `z`, `s` (snow), `e` (energy), `infinity`, `1-2`, `paw` | 8 |
| Card types | `ms-{type}` | `artifact`, `creature`, `instant`, `sorcery`, `enchantment`, `land`, `planeswalker`, `token`, `battle`, `tribal`, `plane`, `conspiracy`, `vanguard` | 17 |
| Tap / untap | `ms-{code}` | `tap`, `untap`, `tap-3ed`, `tap-4ed` | 4 |
| Loyalty | `ms-{code}` | `loyalty-up`, `loyalty-down`, `loyalty-zero`, `loyalty-start`, `defense`, `defense-outline`, `level` | 7 |
| DFC indicators | `ms-dfc-{name}` | `dfc-day`, `dfc-night`, `dfc-spark`, `dfc-meld`, `dfc-modal-face`, `dfc-modal-back`, `dfc-emrakul` | 14 |
| Ability symbols | `ms-ability-{name}` | `ability-flying`, `ability-deathtouch`, `ability-trample`, `ability-hexproof`, `ability-lifelink`, `ability-vigilance`, `ability-haste`, `ability-first-strike` | 150+ |
| Duels abilities | `ms-ability-{name}` | `ability-annihilator`, `ability-infect`, `ability-regenerate` | 40+ |
| Counters | `ms-counter-{name}` | `counter-plus`, `counter-minus`, `counter-shield`, `counter-stun`, `counter-loyalty`, `counter-skull`, `counter-time` | 40+ |
| Guilds | `ms-guild-{name}` | `guild-izzet`, `guild-dimir`, `guild-simic`, `guild-orzhov`, `guild-boros` | 10 |
| Clans | `ms-clan-{name}` | `clan-jeskai`, `clan-mardu`, `clan-sultai`, `clan-temur` | 10 |
| Schools | `ms-school-{name}` | `school-lorehold`, `school-prismari`, `school-quandrix`, `school-silverquill` | 10 |
| Party | `ms-party-{role}` | `party-cleric`, `party-rogue`, `party-warrior`, `party-wizard` | 4 |
| Poleis | `ms-polis-{name}` | `polis-setessa`, `polis-akros`, `polis-meletis` | 3 |
| Color indicators | `ms-ci-{colors}` | `ci-u`, `ci-wu`, `ci-wug`, `ci-5` (5-color) | 20+ |
| Watermarks | `ms-watermark-{name}` | `watermark-mtg`, `watermark-arena`, `watermark-dnd`, `watermark-transformers` | 50+ |
| Misc card symbols | `ms-{code}` | `saga`, `tap`, `chaos`, `acorn`, `ticket`, `multicolor`, `rarity`, `spree`, `flashback` | 10+ |

Full catalog: https://mana.andrewgioia.com/icons.html

## Component API

### `mana_symbol/1` — universal foundation

Renders any symbol in the library by its exact suffix code. All other mana components delegate to this.

```heex
<.mana_symbol symbol="u" cost />
<.mana_symbol symbol="tap" />
<.mana_symbol symbol="ability-flying" size="2x" />
<.mana_symbol symbol="guild-izzet" />
<.mana_symbol symbol="artifact" />
<.mana_symbol symbol="counter-plus" />
<.mana_symbol symbol="loyalty-up" label="Loyalty +1" />
```

Attributes: `:symbol` (required), `:cost` (boolean, round pip style), `:size` (`"2x"`–`"6x"`), `:class` (extra CSS), `:label` (aria-label override, defaults to symbol code).

### `mana_pip/1` — single color pip

Ergonomic wrapper for a single mana color. Accepts `"W"`, `"U"`, `"B"`, `"R"`, `"G"`, `"C"`. Empty/nil renders nothing.

```heex
<.mana_pip color="U" />
<.mana_pip color="W" size="2x" />
```

### `mana_pips/1` — multi-color pip row

Ergonomic wrapper for a color identity string like `"GRW"`. Empty/nil renders a single colorless pip (`ms-c`).

```heex
<.mana_pips colors="GRW" />
<.mana_pips colors={@deck.deck_colors} size="2x" />
```

**Raw `<i class="ms ...">` is forbidden in templates.** All rendering goes through these components. This ensures `role="img"`, `aria-label`, and class composition are applied consistently.

## Modifier Policy

| Modifier | Rule |
|---|---|
| `ms-cost` | For mana color pips only — gives the round pip shape. Pass `cost` attr to `mana_symbol`. Never use on ability/type/tap symbols. |
| `ms-2x` | Deck detail headers (`text-2xl` context). Use `size="2x"` attr. |
| `ms-shadow` | Never on dark background — sufficient contrast without it. |
| `ms-3x`+| Only for dedicated full-screen pip display contexts. |
| `ms-fw` | Fixed-width — use when icons must align in a column (e.g., a stat table). |
| `ms-duo` / `ms-duo-color` / `ms-grad` | Available for multicolor split symbols. Evaluate per use case; not used by default. |

## Colorless Convention

An empty or nil `colors` string means colorless. `mana_pips/1` renders a single `ms-c` pip — never blank space.

## Accessibility

Every rendered `<i>` carries `role="img"` and `aria-label`. These are set by the component; callers never set ARIA attributes directly. For `mana_symbol/1`, the `:label` attr overrides the default (which is the symbol code itself).

## Consequences

**Good:**
- 300+ MTG symbols accessible via a single generic component — any symbol is one line of HEEx
- All rendering encapsulated; no raw `<i class="ms ...">` in templates
- Vendored → pinned version, no network dependency, works offline

**Neutral:**
- Font adds ~184KB (woff2) + ~399KB (woff) to `priv/static/fonts/`. The woff2 is the only one fetched by modern browsers; ~184KB is acceptable for an MTG domain application.

**Risk:**
- If `mana.woff2` is missing from `priv/static/fonts/`, all symbols fail silently (invisible boxes). The required file paths are documented above and in the update instructions in `app.css`.

## Deprecated

`mana_color_class/1` in `core_components.ex` is deprecated (`@doc false`). It will be removed once no call sites remain. Do not use it in new code.
