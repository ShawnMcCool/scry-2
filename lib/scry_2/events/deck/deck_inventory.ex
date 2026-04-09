defmodule Scry2.Events.Deck.DeckInventory do
  @moduledoc """
  Snapshot of the player's full deck collection — names, IDs, and formats.

  Event type: :snapshot

  ## Source

  Produced by `Scry2.Events.IdentifyDomainEvents` from a raw
  `DeckGetDeckSummariesV2` response.
  Fires on login and during periodic deck sync.

  ## Fields

  - `player_id` — MTGA player identifier (may be nil if not yet resolved)
  - `decks` — list of deck summaries, each with `deck_id`, `name`, and `format`

  ## Diff key

  `SnapshotDiff` compares the sorted list of `deck_ids` extracted from `decks`
  to detect additions or removals. Deck contents and names are excluded from
  the diff key — only the presence or absence of a deck ID triggers a new event.

  ## Slug

  `"deck_inventory"` — stable, do not rename.
  """

  @enforce_keys [:decks, :occurred_at]
  defstruct [
    :player_id,
    :decks,
    :occurred_at
  ]

  @type deck_summary :: %{
          deck_id: String.t(),
          name: String.t() | nil,
          format: String.t() | nil
        }

  @type t :: %__MODULE__{
          player_id: String.t() | nil,
          decks: [deck_summary()],
          occurred_at: DateTime.t()
        }

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "deck_inventory"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
