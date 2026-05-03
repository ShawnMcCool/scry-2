defmodule Scry2Web.Components.LiveMatchCard do
  @moduledoc """
  In-flight match card driven by `Scry2.LiveState` poll-tick broadcasts.

  Renders opponent screen name, both ranks, current game number, and
  any commander identities (Brawl). Surfaces only data MTGA does not
  ship in the log stream — opponent rank in particular is the
  log-gap-filler. Hidden when no tick is held (no active match).

  Logic-bearing helpers `view_model/1` and `screen_name_or_nil/1` are
  exposed for unit testing per ADR-013 (no HTML assertions; test the
  pure helper). Rank rendering itself lives in
  `Scry2Web.Components.RankBadge` — the sole place that knows how to
  render an MTGA rank with a Mythic suffix.
  """

  use Phoenix.Component

  alias Scry2.LiveState.RankClass
  alias Scry2.Matches.RankFormat
  alias Scry2Web.Components.RankBadge

  @placeholder_screen_names ["Local Player", "Opponent"]

  attr :tick, :map, default: nil
  attr :commander_names_by_arena_id, :map, default: %{}

  def card(assigns) do
    assigns = assign(assigns, :vm, view_model(assigns.tick))

    ~H"""
    <div
      :if={@vm.active?}
      class="card bg-base-200 shadow-sm border border-primary/20"
      data-test="live-match-card"
    >
      <div class="card-body p-4">
        <div class="flex items-center gap-2 mb-2">
          <span class="badge badge-soft badge-primary text-xs uppercase tracking-wide">
            Live
          </span>
          <h3 class="card-title text-sm uppercase tracking-wide opacity-70">
            Active match
          </h3>
          <span :if={@vm.game_number} class="text-xs opacity-60 ml-auto tabular-nums">
            Game {@vm.game_number}
          </span>
        </div>

        <div class="grid grid-cols-2 gap-4">
          <.player_block
            label="You"
            name={@vm.local_name}
            rank={@vm.local_rank}
            mythic_placement={@vm.local_mythic_placement}
            mythic_percentile={@vm.local_mythic_percentile}
            commanders={commander_labels(@vm.local_commander_arena_ids, @commander_names_by_arena_id)}
          />
          <.player_block
            label="Opponent"
            name={@vm.opponent_name}
            rank={@vm.opponent_rank}
            mythic_placement={@vm.opponent_mythic_placement}
            mythic_percentile={@vm.opponent_mythic_percentile}
            commanders={
              commander_labels(@vm.opponent_commander_arena_ids, @commander_names_by_arena_id)
            }
          />
        </div>
      </div>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :name, :string, default: nil
  attr :rank, :string, default: nil
  attr :mythic_placement, :integer, default: nil
  attr :mythic_percentile, :integer, default: nil
  attr :commanders, :list, default: []

  defp player_block(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-xs uppercase tracking-wide opacity-50">{@label}</span>
      <span class="text-base font-semibold truncate">{@name || "—"}</span>
      <RankBadge.rank_badge
        :if={@rank}
        rank={@rank}
        mythic_placement={@mythic_placement}
        mythic_percentile={@mythic_percentile}
      />
      <span :for={commander <- @commanders} class="text-xs opacity-70 truncate">
        ⌬ {commander}
      </span>
    </div>
    """
  end

  @doc """
  Build a display-ready view model from a `live_match:updates` tick
  payload. `nil` payload → inactive (card hidden).

  Rank fields are split into a base string (composed via
  `RankClass.name/1` + `RankFormat.compose/2`) and the raw mythic
  placement/percentile integers, so the rendering component
  (`Scry2Web.Components.RankBadge`) can format the suffix.
  """
  @spec view_model(map() | nil) :: %{
          active?: boolean(),
          opponent_name: String.t() | nil,
          local_name: String.t() | nil,
          opponent_rank: String.t() | nil,
          opponent_mythic_percentile: integer() | nil,
          opponent_mythic_placement: integer() | nil,
          local_rank: String.t() | nil,
          local_mythic_percentile: integer() | nil,
          local_mythic_placement: integer() | nil,
          game_number: integer() | nil,
          local_commander_arena_ids: [integer()],
          opponent_commander_arena_ids: [integer()]
        }
  def view_model(nil) do
    %{
      active?: false,
      opponent_name: nil,
      local_name: nil,
      opponent_rank: nil,
      opponent_mythic_percentile: nil,
      opponent_mythic_placement: nil,
      local_rank: nil,
      local_mythic_percentile: nil,
      local_mythic_placement: nil,
      game_number: nil,
      local_commander_arena_ids: [],
      opponent_commander_arena_ids: []
    }
  end

  def view_model(%{} = tick) do
    local = Map.get(tick, :local, %{})
    opponent = Map.get(tick, :opponent, %{})
    game_number = Map.get(tick, :current_game_number, 0)

    %{
      active?: true,
      opponent_name: screen_name_or_nil(Map.get(opponent, :screen_name)),
      local_name: screen_name_or_nil(Map.get(local, :screen_name)),
      opponent_rank:
        RankFormat.compose(
          RankClass.name(Map.get(opponent, :ranking_class)),
          nil_if_zero(Map.get(opponent, :ranking_tier))
        ),
      opponent_mythic_percentile: Map.get(opponent, :mythic_percentile),
      opponent_mythic_placement: Map.get(opponent, :mythic_placement),
      local_rank:
        RankFormat.compose(
          RankClass.name(Map.get(local, :ranking_class)),
          nil_if_zero(Map.get(local, :ranking_tier))
        ),
      local_mythic_percentile: Map.get(local, :mythic_percentile),
      local_mythic_placement: Map.get(local, :mythic_placement),
      game_number: if(game_number > 0, do: game_number, else: nil),
      local_commander_arena_ids: Map.get(local, :commander_grp_ids, []),
      opponent_commander_arena_ids: Map.get(opponent, :commander_grp_ids, [])
    }
  end

  # Tier 0 ("no tier") is dropped so sub-Mythic classes render as
  # "Platinum" rather than "Platinum 0". The "None" sentinel from
  # `RankClass.name(0)` and the meaningless Mythic tier are both
  # collapsed inside `RankFormat.compose/2`.
  defp nil_if_zero(0), do: nil
  defp nil_if_zero(other), do: other

  @doc """
  Filter MTGA's tear-down placeholders ("Local Player" / "Opponent")
  and empty strings to `nil`. The walker resets these after a match
  completes — the UI should treat them as absent.
  """
  @spec screen_name_or_nil(String.t() | nil) :: String.t() | nil
  def screen_name_or_nil(nil), do: nil
  def screen_name_or_nil(""), do: nil
  def screen_name_or_nil(name) when name in @placeholder_screen_names, do: nil
  def screen_name_or_nil(name) when is_binary(name), do: name

  defp commander_labels(arena_ids, names_by_arena_id) do
    Enum.map(arena_ids, fn id ->
      Map.get(names_by_arena_id, id) || "##{id}"
    end)
  end
end
