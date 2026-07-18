defmodule Scry2Web.DeckRendering.ViewSpec do
  @moduledoc """
  Declarative parameters for one rendered view of a card list.

  A spec is plain runtime data — not component attrs — so call sites can
  compose any number of views today and UI controls can build or persist
  specs later without touching the engine.

  ## Parameters

  - `group_by` — how entries split into labeled sections:
    `:none` (one unlabeled section), `:type` (Creatures, Instants, …),
    `:broad_type` (the condensed draft-pool vocabulary: Creatures,
    Instants & Sorceries, Artifacts & Enchantments, Lands, Other),
    `:mana_value` (0–7+, Lands last).
  - `display` — `:text` (count + name rows) or `:images`.
  - `piling` — `:piled` merges same-name entries into one card with a
    count (see `count_placement`); `:spread` renders every copy
    individually.
  - `count_placement` — where a piled card's count renders:
    `:badge` overlays a pill on the card image (anchored to a bottom
    corner in `:row`/`:wrap` layouts); `:gutter` reserves a narrow rail
    to the right of the image where the count renders as a dimmed
    number aligned with the card's title strip — blank for single
    copies. `:gutter` is honored only by `:columns` stacks (the only
    layout whose cards are fully edge-aligned); other layouts fall
    back to `:badge`. `:none` suppresses counts entirely — declared by
    callers whose `card_overlay` annotation carries its own count
    (e.g. the deck diff markers). See UIDR-015.
  - `layout` — image arrangement: `:columns` (sections side by side,
    cards vertically splayed — the deck-page main grid), `:row` (one
    horizontally splayed row sized by the `DeckView` JS hook — the
    sideboard), `:wrap` (flat wrap per section — the draft pool).
    Ignored for `display: :text`.
  - `order` — `:sorted` orders cards within a section by mana value
    then name; `:natural` preserves the snapshot's input order (draft
    pack contents, revealed-card zones — anywhere the sequence itself
    is the fact being displayed). Section ordering is always canonical.
  - `splay_depth` — visible fraction between successive card tops in a
    `:columns` stack (0.25 = each card reveals a quarter of its height).
  - `card_width` — CSS width of each card in `:wrap` layouts and the
    fallback width in `:row` layouts (the `DeckView` hook overrides it
    when a `:columns` grid is present in the same view group).
  """

  @type group_by :: :none | :type | :broad_type | :mana_value
  @type display :: :text | :images
  @type piling :: :piled | :spread
  @type count_placement :: :badge | :gutter | :none
  @type layout :: :columns | :row | :wrap
  @type order :: :sorted | :natural

  @type t :: %__MODULE__{
          group_by: group_by(),
          display: display(),
          piling: piling(),
          count_placement: count_placement(),
          layout: layout(),
          order: order(),
          splay_depth: float(),
          card_width: String.t()
        }

  defstruct group_by: :none,
            display: :images,
            piling: :piled,
            count_placement: :badge,
            layout: :wrap,
            order: :sorted,
            splay_depth: 0.25,
            card_width: "4.5rem"
end
