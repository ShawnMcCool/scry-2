defmodule Scry2.Events.Economy.CardsGranted do
  @moduledoc """
  Cards granted to the player by an MTGA-side action — event reward
  (ICR), draft pool grant, voucher redemption, pack open, etc.

  Event type: :fact

  ## Source

  Emitted by `Scry2.Events.IdentifyDomainEvents` from any raw event
  whose `InventoryInfo.Changes` (or `DTO_InventoryInfo.Changes`)
  carries a non-empty `GrantedCards` array.

  Each `Changes` entry produces one `CardsGranted` domain event with
  the `Source` (`"EventReward"`, `"EventGrantCardPool"`,
  `"RedeemVoucher"`, etc.) preserved verbatim. Pack-opens from
  inventory are expected to flow through this same shape with a
  yet-to-be-observed `Source` value.

  ## Fields

  - `player_id` — MTGA player identifier (stamped by ingestion)
  - `source` — verbatim MTGA `Source` code (e.g. `"EventReward"`)
  - `source_id` — MTGA's identifier for the originating action
    (`CourseId`, `EventName`, etc.) when present, otherwise `nil`
  - `cards` — list of grant rows, each `%{arena_id, set_code,
    card_added, vault_progress}`. `card_added: true` means the
    copy joined the collection; `vault_progress > 0` means the
    copy was a duplicate that contributed to vault progress instead.
  - `occurred_at` — MTGA event timestamp

  ## Slug

  `"cards_granted"` — stable, do not rename.
  """

  @behaviour Scry2.Events.DomainEvent

  alias Scry2.Events.Payload

  @enforce_keys [:source, :cards, :occurred_at]
  defstruct [
    :player_id,
    :source,
    :source_id,
    :cards,
    :occurred_at
  ]

  @type grant_row :: %{
          required(:arena_id) => integer(),
          required(:set_code) => String.t() | nil,
          required(:card_added) => boolean(),
          required(:vault_progress) => non_neg_integer()
        }

  @type t :: %__MODULE__{
          player_id: integer() | nil,
          source: String.t(),
          source_id: String.t() | nil,
          cards: [grant_row()],
          occurred_at: DateTime.t()
        }

  def from_payload(payload) do
    %__MODULE__{
      player_id: payload["player_id"],
      source: payload["source"],
      source_id: payload["source_id"],
      cards: decode_cards(payload["cards"]),
      occurred_at: Payload.parse_datetime(payload["occurred_at"])
    }
  end

  defp decode_cards(nil), do: []

  defp decode_cards(cards) when is_list(cards) do
    Enum.map(cards, fn row ->
      %{
        arena_id: row["arena_id"] || row[:arena_id],
        set_code: row["set_code"] || row[:set_code],
        card_added: row["card_added"] || row[:card_added] || false,
        vault_progress: row["vault_progress"] || row[:vault_progress] || 0
      }
    end)
  end

  defimpl Scry2.Events.Event do
    def type_slug(_), do: "cards_granted"
    def mtga_timestamp(%{occurred_at: ts}), do: ts
  end
end
