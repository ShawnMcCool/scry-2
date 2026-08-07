defmodule Scry2Web.DeckRendering.Ownership do
  @moduledoc """
  The ownership layer of the deck rendering engine: how every card list
  in the app shows what the player is missing.

  A `Scry2.Buildability.Assessment` in, the three
  `Scry2Web.DeckRendering.deck_view/1` hooks out —

    * `card_class/1` tints text rows the player is short of,
    * `count_entry/1` tones the gutter-rail / badge count and carries the
      ownership tooltip (UIDR-015 — counts never cover printed card
      information),
    * `wash/1` dims unowned card images.

  `standard_composition/1` wires all three from its `ownership` attr, so
  pages pass the assessment and nothing else. `craft_summary/1` is the
  aggregate companion: what the whole list would cost in wildcards.

  ## Unknown collection

  `rows_index/1` returns `%{}` for an assessment whose
  `collection_known?` is false. With no snapshot every card scores as
  missing, which is *unknown*, not fact — annotating it would tell the
  player they own nothing.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents, only: [icon: 1]
  import Scry2Web.WildcardCost, only: [cost_pips: 1, balance_row: 1]

  alias Scry2.Buildability.Assessment
  alias Scry2.Buildability.CardRow
  alias Scry2Web.WildcardCost

  @type rows :: %{integer() => CardRow.t()}

  # ── Deck view hooks ─────────────────────────────────────────────────

  @doc """
  Per-card rows indexed by arena_id, from an `Assessment`, an
  already-built index, or nil. Empty when the collection is unknown.
  """
  @spec rows_index(Assessment.t() | rows() | nil) :: rows()
  def rows_index(nil), do: %{}
  def rows_index(%Assessment{collection_known?: false}), do: %{}
  def rows_index(%Assessment{} = assessment), do: Assessment.rows_by_arena_id(assessment)
  def rows_index(rows) when is_map(rows), do: rows

  @doc """
  The text view's `card_class` function: warning tone for cards the
  player is short of, default colour otherwise.
  """
  @spec card_class(Assessment.t() | rows() | nil) :: (map() -> String.t() | nil)
  def card_class(ownership) do
    rows = rows_index(ownership)

    fn card ->
      case Map.get(rows, card.arena_id) do
        %CardRow{missing: missing} when missing > 0 -> "text-warning"
        _row -> nil
      end
    end
  end

  @doc """
  The deck view's `count_entry` function (UIDR-015/017): counts render in
  the gutter rail (or splay badge), toned by ownership, with the
  ownership tooltip. Blank means one fully-owned copy; cards with missing
  copies always show their count. Cards without an ownership row fall
  back to the plain count.
  """
  @spec count_entry(Assessment.t() | rows() | nil) :: (map() -> map() | nil)
  def count_entry(ownership) do
    rows = rows_index(ownership)

    fn card ->
      case Map.get(rows, card.arena_id) do
        nil ->
          plain_count(card.count)

        %CardRow{free?: true} = row ->
          %{label: to_string(card.count), class: row_tone(:free), title: title(row)}

        %CardRow{missing: missing} = row when missing > 0 ->
          %{
            label: to_string(card.count),
            class: row |> row_state() |> row_tone(),
            title: title(row)
          }

        %CardRow{} = row ->
          case plain_count(card.count) do
            nil -> nil
            entry -> %{entry | class: row_tone(:owned), title: title(row)}
          end
      end
    end
  end

  # Blank means one — the rail only carries information.
  defp plain_count(count) when is_integer(count) and count > 1,
    do: %{label: to_string(count), class: nil, title: nil}

  defp plain_count(_count), do: nil

  @doc """
  Per-card ownership state: `:free` (basic land), `:owned` (have all
  needed), `:missing` (own none), `:partial` (own some but not all).
  """
  @spec row_state(CardRow.t() | nil) :: :free | :owned | :missing | :partial | nil
  def row_state(nil), do: nil
  def row_state(%CardRow{free?: true}), do: :free
  def row_state(%CardRow{missing: 0}), do: :owned
  def row_state(%CardRow{owned: 0}), do: :missing
  def row_state(%CardRow{}), do: :partial

  @doc "Text-colour class for an ownership state."
  @spec row_tone(:free | :owned | :missing | :partial) :: String.t()
  def row_tone(:free), do: "text-base-content/30"
  def row_tone(:owned), do: "text-success"
  def row_tone(:missing), do: "text-warning"
  def row_tone(:partial), do: "text-base-content/60"

  @doc "Tooltip describing a card's ownership, or nil without a row."
  @spec title(CardRow.t() | nil) :: String.t() | nil
  def title(nil), do: nil
  def title(%CardRow{free?: true} = row), do: "#{row.name} — basic land"
  def title(%CardRow{} = row), do: "#{row.name} — #{row.owned}/#{row.needed} owned"

  # ── Components ──────────────────────────────────────────────────────

  @doc """
  Annotation drawn over a card image: unowned copies dim the card.
  Counts render in the deck view's gutter rail / splay badge via
  `count_entry/1` (UIDR-015), so nothing printed on the card is covered.
  """
  attr :row, :any, default: nil

  def wash(assigns) do
    assigns = assign(assigns, :dim?, row_state(assigns.row) in [:missing, :partial])

    ~H"""
    <div
      :if={@dim?}
      class="absolute inset-0 rounded-sm bg-base-100/60 pointer-events-none"
      title={title(@row)}
    />
    """
  end

  @doc """
  What the whole list would cost: maindeck wildcards, sideboard
  wildcards, and the player's balances. Buildability status keys off the
  maindeck only, so the sideboard block is purely informational.

  Renders nothing when the collection is unknown — see the moduledoc.
  """
  attr :assessment, :any, required: true
  attr :class, :any, default: nil

  attr :subject, :string,
    default: "this list",
    doc: ~s(Named in the incomplete warning — e.g. "this decklist".)

  def craft_summary(%{assessment: %Assessment{collection_known?: true}} = assigns) do
    ~H"""
    <div class={["space-y-4", @class]}>
      <div>
        <.summary_heading>Maindeck — to craft</.summary_heading>
        <div
          :if={WildcardCost.any?(@assessment.result.maindeck.wildcard_cost)}
          class="flex items-center gap-3"
        >
          <.cost_pips cost={@assessment.result.maindeck.wildcard_cost} size="size-5" />
        </div>
        <p
          :if={!WildcardCost.any?(@assessment.result.maindeck.wildcard_cost)}
          class="text-sm text-success"
        >
          You own the full maindeck.
        </p>
        <p
          :if={@assessment.result.status == :short}
          class="text-xs text-warning mt-2 flex items-center gap-2"
        >
          Still need <.cost_pips cost={@assessment.result.maindeck.shortfall} />
          beyond your wildcards.
        </p>
        <p :if={@assessment.result.status == :craftable} class="text-xs text-info mt-2">
          You have the wildcards to craft this now.
        </p>
        <p
          :if={@assessment.result.status == :incomplete}
          class="text-xs text-warning mt-2 flex items-center gap-2"
        >
          <.icon name="hero-exclamation-triangle" class="size-3.5 shrink-0" />
          Some cards in {@subject} aren't on MTGA — it can't be fully built,
          no matter your wildcards.
        </p>
      </div>

      <div :if={@assessment.result.sideboard.total_copies > 0}>
        <.summary_heading>Sideboard — to craft</.summary_heading>
        <.cost_pips
          :if={WildcardCost.any?(@assessment.result.sideboard.wildcard_cost)}
          cost={@assessment.result.sideboard.wildcard_cost}
        />
        <p
          :if={!WildcardCost.any?(@assessment.result.sideboard.wildcard_cost)}
          class="text-sm text-success"
        >
          You own the full sideboard.
        </p>
      </div>

      <div>
        <.summary_heading>Your wildcards</.summary_heading>
        <.balance_row wildcards={@assessment.wildcards} />
      </div>
    </div>
    """
  end

  def craft_summary(assigns) do
    ~H""
  end

  slot :inner_block, required: true

  defp summary_heading(assigns) do
    ~H"""
    <h3 class="text-xs font-semibold text-base-content/40 uppercase tracking-widest mb-2">
      {render_slot(@inner_block)}
    </h3>
    """
  end

  @doc """
  The quiet stand-in for the craft summary when there is no collection
  snapshot: says what's missing and why, without pretending the player
  owns nothing.
  """
  attr :class, :any, default: nil

  def unknown_collection_note(assigns) do
    ~H"""
    <p class={["text-xs text-base-content/45", @class]}>
      Turn on collection reading in Settings to see which cards you're missing and what
      this would cost in wildcards.
    </p>
    """
  end
end
