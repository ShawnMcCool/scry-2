# Campaign: find more netdeck sources

**Status:** active · **Started:** 2026-07-22 · **Owner:** Shawn + Claude

Round 2 of the NetDecking source survey. The original 2026-06-28 research
(`docs/superpowers/specs/2026-06-28-netdecking-sourcing-research.md`) picked
the sources that shipped (Local JSON feed, MTGO) and rejected the hostile
tier (MTGGoldfish, AetherHub, mtgdecks.net, MTGJSON-as-feed, Moxfield). This
campaign looks for **more** candidates under the same conservative bar: no
Cloudflare challenge-solving, honor robots.txt (including named AI-bot
blocks), prefer first-party or MTGA-clipboard-native sources over
name-only HTML scraping.

**Next session should:** build `HareruyaSource`/`HareruyaExtract` (see
[Recommendation](#recommendation) + [Open questions](#open-questions-before-building)),
or — if not building yet — run a round-3 survey against the still-unconfirmed
candidates listed under [Round 2 survey](#round-2-survey-2026-07-22).

---

## Stage status

| Stage | Status | Notes |
|---|---|---|
| Round 2 survey (find + verify new candidates) | ✅ done (2026-07-22) | 3 new candidates resolved: Hareruya adopt, Melee.gg reject, MTG Arena Zone reject |
| Hareruya live scrapability check (robots.txt / Cloudflare / ToS) | ✅ done (2026-07-22) | All three checked directly — clean on all counts, see table below |
| `HareruyaSource` + `HareruyaExtract` adapter | ⬜ not started | Follow the `MtgoSource`/`MtgoExtract` pattern; open questions below gate the start |
| Round 3 survey (unconfirmed candidates) | ⬜ not started | TCGplayer, StarCityGames, MTGMeta.io, Archidekt's API, WotC in-client Metagame Challenge, Reddit, Limitless — see "Unconfirmed" below |

---

## North star

Every source lives or dies on the same three questions the original
research established:

1. Is it scrapable without spoofing a browser UA or solving a bot challenge?
2. Does its robots.txt/ToS actually permit automated retrieval — explicit
   AI-bot disallows (`anthropic-ai`, `Claude-Web`, `ClaudeBot`, `GPTBot`)
   are a hard reject regardless of a permissive wildcard rule underneath?
3. Does it ship MTGA-clipboard-format text (cleanest `arena_id` resolution
   path) or only bare names (falls back to case-insensitive name match)?

---

## Round 2 survey (2026-07-22)

Ran via the `deep-research` workflow (5 search angles, 18 sources fetched,
56 claims extracted, 25 adversarially verified 3-vote) against a brief that
named eight candidates to check (Melee.gg, TCGplayer, StarCityGames,
MTGAZone, MTGMeta.io, Archidekt, Hareruya/MagicVille, WotC in-client
Metagame Challenge) plus whatever else search surfaced. Hareruya's
scrapability signals (robots.txt, Cloudflare presence, ToS) were flagged as
unverified by the workflow and were checked live afterward in this session.

| Source | API? | MTGA export string? | Bot protection | robots.txt (AI bots) | Legal/ToS posture | Standard freshness | Verdict |
|---|---|---|---|---|---|---|---|
| **Hareruya** (hareruyamtg.com) | No — HTML deck-search UI | **Yes** — individual deck pages expose a literal "Text in MTG Arena format" clipboard block | **None.** Verified live: direct `curl` with a generic UA returns HTTP 200 immediately (Apache + AWS ALB, no Cloudflare/JS challenge) | **Clean.** Verified live: wildcard `User-agent: *` is `Allow: /`; no AI-bot-named blocks (no `anthropic-ai`/`Claude-Web`/`GPTBot` entries at all); only disallows bulk export paths (`/en/deck/download/*`, `/en/deck/bulk/*`, `/en/deck/result?*`) — not individual deck pages or the `/en/deck/` search index | Verified live: Terms of Use has no anti-scraping/automated-access clause; one general anti-redistribution clause (don't republish content to third parties, not about retrieval method) | Live, dated Standard metagame snapshot (`2026/07/09`) with named archetypes + deck counts (e.g. Izzet Prowess 38 decks/13.97%) | **Adopt — build queue** |
| **Melee.gg** | Permissioned partner API only — access requires emailing `contact@melee.gg`, gated to org owners/staff, third-party org data needs that org's explicit sign-off (PII risk cited) | Not documented anywhere in player-facing help | Not confirmed either way this round | Disallows exactly `/Decklist/View/`, `/Decklist/Index/`, `/Decklist/SearchCardNames/`, `/Tournament/Search/`, `/Tournament/SearchResults/`, `/Card/` — precisely the paths a scraper would need | Decklists are hidden by default; public only if the tournament organizer opts in per-event via a toggle — not a default-public dataset | High (hosts many paper Standard events) but access-gated | **Reject** |
| **MTG Arena Zone** (mtgazone.com) | None found | None found | Not observed / not tested | **Explicitly disallows `anthropic-ai` and `Claude-Web` by name** (`Disallow: /`), alongside GPTBot, ChatGPT-User, CCbot, PiplBot, FacebookBot; a separate wildcard block is open, but the named block is the operative signal of site-owner intent | Named, unambiguous exclusion of Claude-branded agents specifically | Standard deck-tech articles; cadence unclear | **Reject** |

**Unconfirmed, not settled either way:** Archidekt's public API, TCGplayer
deck-tech content, StarCityGames, MTGMeta.io, WotC's in-client "Metagame
Challenge" pages (if distinct from magic.gg), Reddit competitive
communities, and Limitless-style aggregators — none produced a verified
finding this round (search didn't surface a decisive source, or a claim
about them was refuted). Archidekt specifically: a claim that its search UI
skews Commander-only with no Standard filter was **refuted 0-3** — genuinely
open, not rejected. These are the natural next round.

### Links for review

**Hareruya:**
- Deck search / metagame index — https://www.hareruyamtg.com/en/deck/
- Standard metagame snapshot — https://www.hareruyamtg.com/en/deck/1/metagame/
- Example individual deck page (has the "Text in MTG Arena format" export block) — https://www.hareruyamtg.com/en/deck/1216588/show/
- Arena-import help page — https://www.hareruyamtg.com/en/user_data/adjust_for_arena
- robots.txt — https://www.hareruyamtg.com/robots.txt
- Terms of Use — https://www.hareruyamtg.com/en/user_data/rules_en

**Melee.gg:**
- Decklists page (redirects to sign-in when logged out) — https://melee.gg/Decklists
- robots.txt — https://melee.gg/robots.txt
- API access policy — https://help.melee.gg/docs/api-use/
- Decklists-for-players help doc — https://help.melee.gg/docs/decklists-for-players/
- Decklists-for-organizers help doc — https://help.melee.gg/docs/decklists-a-help-guide-for-organizers/

**MTG Arena Zone:**
- robots.txt (names `anthropic-ai`/`Claude-Web`) — https://mtgazone.com/robots.txt
- Standard decks listing — https://mtgazone.com/decks/standard/
- Standard metagame page — https://mtgazone.com/metagame/standard/

**Archidekt** (unconfirmed, round-3 candidate):
- Deck search — https://archidekt.com/search/decks

---

## Recommendation

**Add Hareruya to the adapter build queue**, following the exact
`MtgoSource`/`MtgoExtract` pattern from
`docs/superpowers/plans/2026-06-29-netdecking-automated-sourcing.md`:
`HareruyaSource` (Req-isolated HTTP, honest UA, capped events/run,
inter-request delay) + `HareruyaExtract` (pure HTML → `[raw_deck]`, tested
against a captured fixture). Ship it **opt-in**, same tier as the deferred
`MtgTop8Source` — third-party, not WotC-first-party, spot-checked in one
session rather than the deeper original survey.

Hareruya is a genuine step up from MTGTop8's "opt-in secondary" verdict: it
ships literal MTGA clipboard text per deck (the same clean `(SET) collector`
resolution path as the local feed and the deferred Untapped source),
whereas MTGTop8's export format was never confirmed to include set/collector
data.

No changes to the existing reject list. Melee.gg and MTG Arena Zone are
added to it for completeness — future re-checks shouldn't re-spend research
budget re-discovering them.

---

## Open questions before building

1. **Enumeration path.** How to list "current Standard decks" on Hareruya —
   crawl `/en/deck/` with a Standard filter to collect individual deck-page
   URLs, then fetch each `/en/deck/{id}/show/` page for its MTGA-format
   block? Needs a live page-structure probe (mirror the MtgoSource
   discipline: probe first, then build test-first against a captured
   fixture) before writing the extractor.
2. **Politeness cadence.** ToS states no explicit crawl-delay or rate limit.
   Self-impose the same posture as `MtgoSource` (honest UA
   `scry2/<version> (+repo-url)`, capped events per run, small
   inter-request delay) even absent a stated requirement.
3. **Re-verify at build time.** Bot-protection and robots.txt posture drift
   over months — re-check immediately before building, same caveat the
   original research doc carries.

---

## Session log

- **2026-07-22** — Ran the `deep-research` workflow (5 angles, 18 sources,
  56 claims → 25 verified) to find decklist sources beyond the June 28
  survey. Found three new candidates: **Melee.gg** (reject — auth-walled
  decklist browsing, robots.txt disallows the exact scraper paths,
  permissioned-only API), **MTG Arena Zone** (reject — robots.txt names
  `anthropic-ai`/`Claude-Web` explicitly with `Disallow: /`), **Hareruya**
  (flagged promising but pending bot-protection/ToS verification — the
  workflow confirmed the MTGA-clipboard export live but didn't check
  robots.txt/Cloudflare/ToS). Personally verified Hareruya's remaining
  unknowns live: robots.txt (no AI-bot block, wildcard `Allow: /`, only
  bulk-export subpaths disallowed), direct `curl` (no Cloudflare — plain
  Apache/AWS ALB, HTTP 200 immediately), and Terms of Use (no
  anti-scraping clause). **Upgraded Hareruya to Adopt — build queue.**
  Real gap: the broader candidate list from the research brief (TCGplayer,
  StarCityGames, MTGMeta.io, Archidekt's API, WotC's in-client Metagame
  Challenge, Reddit, Limitless) wasn't meaningfully checked this round —
  listed above as the open follow-up, not silently dropped.

---

## References

- `docs/superpowers/specs/2026-06-28-netdecking-sourcing-research.md` — round 1 survey (9 sources, adopted/rejected)
- `docs/superpowers/plans/2026-06-29-netdecking-automated-sourcing.md` — shipped adapter implementation plan; the pattern to follow for `HareruyaSource`
- `decisions/architecture/2026-06-29-040-netdecking-automated-sourcing.md` — ADR for the shipped sources
- `lib/scry_2/net_decking/sources/` — existing adapters (`LocalJsonSource`, `MtgoSource`/`MtgoExtract`)
- skill: `deep-research`
