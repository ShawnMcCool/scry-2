# UI Refresh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the halloween-colored dual theme with a single cool-slate dark theme, add DPI-responsive scaling, enlarge mulligan card images, add flat row styling, and add a hover card detail popup.

**Architecture:** CSS theme changes in `app.css` (replace dual themes with one dark), root `clamp()` font for DPI scaling, LiveView template updates for flat rows + larger cards, and a JS hook for cursor-following card hover popup.

**Tech Stack:** Tailwind 4, DaisyUI themes, Phoenix LiveView JS hooks

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `assets/css/app.css` | Modify | Single dark theme, remove light, add clamp() root font |
| `lib/scry_2_web/components/layouts/root.html.heex` | Modify | Hardcode dark theme, remove theme JS, add hover popup div |
| `lib/scry_2_web/components/layouts.ex` | Modify | Remove theme_toggle component, remove its usage in navbar |
| `lib/scry_2_web/components/card_components.ex` | Modify | Add phx-hook, update default sizes to rem |
| `assets/js/app.js` | Modify | Register CardHover hook |
| `assets/js/hooks/card_hover.js` | Create | CardHover hook — popup follows cursor |
| `lib/scry_2_web/live/mulligans_live.ex` | Modify | Flat rows, larger cards, dim mulligans |
| `lib/scry_2_web/live/mulligans_helpers.ex` | Modify | Update badge classes (green pill, grey pill), remove border helper |
| `test/scry_2_web/live/mulligans_helpers_test.exs` | Modify | Update assertions |

---

### Task 1: Single dark theme + DPI scaling

**Files:**
- Modify: `assets/css/app.css`
- Modify: `lib/scry_2_web/components/layouts/root.html.heex`
- Modify: `lib/scry_2_web/components/layouts.ex`

- [ ] **Step 1: Replace dual themes with single dark theme in `assets/css/app.css`**

Replace lines 24–100 (both theme plugins + the `@custom-variant dark` line) with:

```css
@plugin "../vendor/daisyui-theme" {
  name: "dark";
  default: true;
  prefersdark: true;
  color-scheme: "dark";
  --color-base-100: oklch(22% 0.012 250);
  --color-base-200: oklch(19% 0.010 250);
  --color-base-300: oklch(16% 0.008 250);
  --color-base-content: oklch(93% 0.005 250);
  --color-primary: oklch(68% 0.15 270);
  --color-primary-content: oklch(96% 0.01 270);
  --color-secondary: oklch(60% 0.08 250);
  --color-secondary-content: oklch(96% 0.01 250);
  --color-accent: oklch(68% 0.15 270);
  --color-accent-content: oklch(96% 0.01 270);
  --color-neutral: oklch(30% 0.02 250);
  --color-neutral-content: oklch(93% 0.005 250);
  --color-info: oklch(68% 0.15 270);
  --color-info-content: oklch(96% 0.01 270);
  --color-success: oklch(72% 0.19 155);
  --color-success-content: oklch(98% 0.01 155);
  --color-warning: oklch(75% 0.15 85);
  --color-warning-content: oklch(98% 0.01 85);
  --color-error: oklch(65% 0.2 25);
  --color-error-content: oklch(96% 0.01 25);
  --radius-selector: 0.25rem;
  --radius-field: 0.25rem;
  --radius-box: 0.5rem;
  --size-selector: 0.21875rem;
  --size-field: 0.21875rem;
  --border: 1px;
  --depth: 0;
  --noise: 0;
}
```

Remove the `@custom-variant dark` line entirely (line ~100).

- [ ] **Step 2: Add responsive root font size**

Add after the `@plugin` blocks, before the `@custom-variant phx-click-loading` line:

```css
/* Responsive root font — scales with viewport for DPI adaptation */
html {
  font-size: clamp(14px, 0.85vw + 6px, 18px);
}
```

- [ ] **Step 3: Simplify root layout**

Replace the entire contents of `lib/scry_2_web/components/layouts/root.html.heex` with:

```heex
<!DOCTYPE html>
<html lang="en" data-theme="dark">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <meta name="csrf-token" content={get_csrf_token()} />
    <.live_title default="Scry2" suffix=" · Scry2">
      {assigns[:page_title]}
    </.live_title>
    <link phx-track-static rel="stylesheet" href={~p"/assets/css/app.css"} />
    <script defer phx-track-static type="text/javascript" src={~p"/assets/js/app.js"}>
    </script>
  </head>
  <body>
    {@inner_content}
    <!-- Shared card hover popup — repositioned by CardHover hook -->
    <div id="card-hover-popup" style="display:none; position:fixed; z-index:100; pointer-events:none;">
      <img id="card-hover-popup-img" src="" alt="" style="width:250px; border-radius:8px; box-shadow: 0 8px 32px rgba(0,0,0,0.6);" />
    </div>
  </body>
</html>
```

Key changes: hardcoded `data-theme="dark"`, removed theme-switching JS, added hover popup div.

- [ ] **Step 4: Remove theme toggle from navbar**

In `lib/scry_2_web/components/layouts.ex`, find the line `<li><.theme_toggle /></li>` (around line 59) and remove it.

Then remove the entire `theme_toggle/1` function (lines ~154-189).

- [ ] **Step 5: Verify compilation and run tests**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
```

Expected: all pass, zero warnings.

---

### Task 2: CardHover JS hook

**Files:**
- Create: `assets/js/hooks/card_hover.js`
- Modify: `assets/js/app.js`

- [ ] **Step 1: Create the CardHover hook**

Create `assets/js/hooks/card_hover.js`:

```javascript
// CardHover — shows a large card preview near the cursor on hover.
// Attached to <img> elements via phx-hook="CardHover".
// Uses a shared popup element (#card-hover-popup) in root layout.

export const CardHover = {
  mounted() {
    this.popup = document.getElementById("card-hover-popup")
    this.popupImg = document.getElementById("card-hover-popup-img")

    this.el.addEventListener("mouseenter", (e) => {
      const src = this.el.src
      if (!src) return

      this.popupImg.src = src
      this.popupImg.alt = this.el.alt
      this.popup.style.display = "block"
      this._position(e)
    })

    this.el.addEventListener("mousemove", (e) => {
      this._position(e)
    })

    this.el.addEventListener("mouseleave", () => {
      this.popup.style.display = "none"
      this.popupImg.src = ""
    })
  },

  _position(e) {
    const offset = 20
    const popupW = 250
    const popupH = 350 // approximate
    let x = e.clientX + offset
    let y = e.clientY + offset

    // Clamp to viewport edges
    if (x + popupW > window.innerWidth) x = e.clientX - popupW - offset
    if (y + popupH > window.innerHeight) y = e.clientY - popupH - offset
    if (x < 0) x = 0
    if (y < 0) y = 0

    this.popup.style.left = x + "px"
    this.popup.style.top = y + "px"
  }
}
```

- [ ] **Step 2: Register hook in app.js**

In `assets/js/app.js`, add the import after the Console import:

```javascript
import {CardHover} from "./hooks/card_hover"
```

Update the hooks object in the LiveSocket constructor:

```javascript
hooks: {...colocatedHooks, Console, CardHover},
```

- [ ] **Step 3: Verify compilation**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors
```

---

### Task 3: Update card_image component with hook + rem sizing

**Files:**
- Modify: `lib/scry_2_web/components/card_components.ex`

- [ ] **Step 1: Update card_image to use hook and rem default size**

In `lib/scry_2_web/components/card_components.ex`, update the `card_image/1` function:

Change the default class from `"w-20"` to `"w-[4.5rem]"`:

```elixir
attr :class, :string, default: "w-[4.5rem]"
```

Add `phx-hook="CardHover"` and a unique `id` to the `<img>` tag (hooks require an id):

```elixir
def card_image(assigns) do
  assigns =
    assigns
    |> assign(:src, ImageCache.url_for(assigns.arena_id))
    |> assign(:cached?, ImageCache.cached?(assigns.arena_id))

  ~H"""
  <img
    :if={@cached?}
    id={"card-img-#{@arena_id}"}
    src={@src}
    alt={@name}
    loading="lazy"
    class={["rounded-sm", @class]}
    phx-hook="CardHover"
  />
  <div
    :if={!@cached?}
    class={[
      "rounded-sm bg-base-300 flex items-center justify-center text-base-content/20 aspect-[488/680]",
      @class
    ]}
  >
    <Scry2Web.CoreComponents.icon name="hero-photo" class="size-4" />
  </div>
  """
end
```

Also update the default class in `card_hand/1` to match:

```elixir
attr :class, :string, default: "w-[4.5rem]"
```

- [ ] **Step 2: Verify compilation**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix compile --warnings-as-errors
```

---

### Task 4: Mulligans — flat rows, larger cards, dim mulligans (TDD)

**Files:**
- Modify: `lib/scry_2_web/live/mulligans_helpers.ex`
- Modify: `test/scry_2_web/live/mulligans_helpers_test.exs`
- Modify: `lib/scry_2_web/live/mulligans_live.ex`

- [ ] **Step 1: Update helper tests**

In `test/scry_2_web/live/mulligans_helpers_test.exs`:

Update `decision_badge_class` test:

```elixir
describe "decision_badge_class/1" do
  test "returns badge classes" do
    assert MulligansHelpers.decision_badge_class(:kept) == "bg-success/10 text-success"
    assert MulligansHelpers.decision_badge_class(:mulliganed) == "bg-base-content/5 text-base-content/40"
  end
end
```

Remove the entire `decision_border_class/1` describe block.

- [ ] **Step 2: Run tests to verify RED**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/mulligans_helpers_test.exs
```

- [ ] **Step 3: Update helpers**

In `lib/scry_2_web/live/mulligans_helpers.ex`:

Update badge class:

```elixir
@spec decision_badge_class(:kept | :mulliganed) :: String.t()
def decision_badge_class(:kept), do: "bg-success/10 text-success"
def decision_badge_class(:mulliganed), do: "bg-base-content/5 text-base-content/40"
```

Remove the `decision_border_class/1` function entirely.

- [ ] **Step 4: Run tests to verify GREEN**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix test test/scry_2_web/live/mulligans_helpers_test.exs
```

- [ ] **Step 5: Update mulligans_live.ex render**

Replace the render function's hand row template. The new row design:

```elixir
@impl true
def render(assigns) do
  ~H"""
  <Layouts.console_mount socket={@socket} />
  <Layouts.app flash={@flash} players={@players} active_player_id={@active_player_id}>
    <h1 class="text-2xl font-semibold mb-6">Mulligans</h1>

    <.empty_state :if={@matches == []}>
      No mulligan data recorded yet. Play a game with MTGA detailed logs enabled.
    </.empty_state>

    <div :for={match <- @matches} class="mb-10">
      <div class="flex items-center gap-2 mb-4">
        <span class="text-xs text-base-content/30 uppercase tracking-wider font-semibold">
          Match
        </span>
        <.link
          :if={match.match_id}
          navigate={~p"/events?match_id=#{match.match_id}"}
          class="font-mono text-xs text-accent/60 hover:text-accent"
        >
          {truncate_id(match.match_id)}
        </.link>
      </div>

      <div class="flex flex-col gap-4">
        <div
          :for={{offer, decision} <- match.hands}
          class={["flex items-center gap-4", decision == :mulliganed && "opacity-45"]}
        >
          <div class="w-[5rem] shrink-0">
            <span class={[
              "inline-block px-3 py-1 rounded-full text-xs font-semibold",
              MulligansHelpers.decision_badge_class(decision)
            ]}>
              {MulligansHelpers.decision_label(decision)}
            </span>
          </div>

          <div :if={offer.hand_arena_ids} class="flex-1">
            <.card_hand arena_ids={offer.hand_arena_ids} class="w-[4.5rem]" />
          </div>
          <span :if={!offer.hand_arena_ids} class="flex-1 text-base-content/20">—</span>
        </div>
      </div>
    </div>
  </Layouts.app>
  """
end
```

Key changes vs current: no border-l, no bg-base-200, no `rounded-lg`, `opacity-45` on mulliganed, pill badge with `rounded-full`, larger cards at `w-[4.5rem]`, removed "N cards" label (visual count is obvious).

- [ ] **Step 6: Run full precommit**

```bash
MIX_OS_DEPS_COMPILE_PARTITION_COUNT=8 mix precommit
```

---

### Task 5: Visual verification

- [ ] **Step 1: Open http://localhost:4002/mulligans**

Verify:
- Cool slate dark background (not black, not purple)
- No orange anywhere
- Kept hands at full opacity with green pill badge
- Mulliganed hands dimmed to ~45% opacity with grey pill badge
- Card images large (~72px wide), no left border accent
- No row backgrounds, flat on page
- Hover over a card image — large preview popup follows cursor
- Resize browser window — UI scales smoothly with viewport

- [ ] **Step 2: Check other pages still look correct**

Visit `/`, `/matches`, `/cards`, `/drafts` — ensure the new theme applies consistently.
