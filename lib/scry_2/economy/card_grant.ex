defmodule Scry2.Economy.CardGrant do
  @moduledoc """
  Schema for one card-grant batch — every time MTGA's log carries a
  `Changes[*].GrantedCards` payload, the projection writes one
  `economy_card_grants` row with the full list of cards granted by
  that change.

  Sources observed in real logs (April 2026):

    * `EventReward` — Individual Card Rewards (ICR) earned from
      claiming an event prize. 1 card per win, occasionally more for
      higher-prize events.
    * `EventGrantCardPool` — the entire 80-ish card pool granted
      after a draft completes. Carried in
      `BotDraftDraftPick`'s `DTO_InventoryInfo` rather than the
      regular `InventoryInfo`.
    * `RedeemVoucher` — cards from a voucher redemption.
    * `EventReward` (in Pack-A-Day style events) — packs that are
      auto-opened on claim are emitted as a single `Changes` entry
      with a long `GrantedCards` list.

  Pack-open events from inventory (the user clicking "Open" on a
  booster they own) have not yet been observed in the dataset so the
  exact `Source` code is unverified — they should appear via this
  same shape when they do, with no further code changes.

  ## Disposable

  Rebuilt from the domain event log via
  `Scry2.Economy.EconomyProjection.rebuild!/0`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "economy_card_grants" do
    field :source, :string
    field :source_id, :string
    # Stored as JSON-shaped %{"items" => [%{"arena_id", "set_code", ...}]}
    # to match the project convention for list-of-map data in :map columns
    # (see Economy.Transaction.boosters wrapping pattern).
    field :cards, :map
    field :card_count, :integer
    field :occurred_at, :utc_datetime_usec
    field :from_snapshot_id, :id
    field :to_snapshot_id, :id

    timestamps(type: :utc_datetime_usec)
  end

  @cast_fields [
    :source,
    :source_id,
    :cards,
    :card_count,
    :occurred_at,
    :from_snapshot_id,
    :to_snapshot_id
  ]

  @required [:source, :cards, :card_count, :occurred_at]

  @doc "Build a changeset for inserting a card-grant row."
  @spec changeset(t() | %__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(grant, attrs) do
    grant
    |> cast(attrs, @cast_fields)
    |> validate_required(@required)
  end

  @doc """
  Wrap a list of card-grant rows for storage in the `:cards` field.
  The wrapper avoids the array-as-top-level-JSON storage that some
  Ecto adapters do not handle uniformly with `:map` typed columns.
  """
  @spec wrap_cards([map()]) :: map()
  def wrap_cards(cards) when is_list(cards), do: %{"items" => cards}

  @doc "Unwrap the stored `:cards` map into the list of grant rows."
  @spec unwrap_cards(map() | nil) :: [map()]
  def unwrap_cards(%{"items" => items}) when is_list(items), do: items
  def unwrap_cards(_), do: []
end
