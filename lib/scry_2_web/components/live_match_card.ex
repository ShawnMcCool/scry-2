defmodule Scry2Web.Components.LiveMatchCard do
  @moduledoc """
  In-flight match card driven by `Scry2.LiveState` poll-tick broadcasts.

  Renders opponent screen name, both ranks, current game number, and
  any commander identities (Brawl). Surfaces only data MTGA does not
  ship in the log stream — opponent rank in particular is the
  log-gap-filler. Hidden when no tick is held (no active match).

  Logic-bearing helpers `view_model/1`, `format_rank/4`, and
  `screen_name_or_nil/1` are exposed for unit testing per ADR-013
  (no HTML assertions; test the pure helper).
  """

  use Phoenix.Component

  # Order matches MTGA's RankingClass enum: index 0 = None.
  # See `.claude/skills/mono-memory-reader/SKILL.md`.
  @rank_class_labels {nil, "Bronze", "Silver", "Gold", "Platinum", "Diamond", "Mythic"}

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
            commanders={commander_labels(@vm.local_commander_arena_ids, @commander_names_by_arena_id)}
          />
          <.player_block
            label="Opponent"
            name={@vm.opponent_name}
            rank={@vm.opponent_rank}
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
  attr :commanders, :list, default: []

  defp player_block(assigns) do
    ~H"""
    <div class="flex flex-col gap-0.5">
      <span class="text-xs uppercase tracking-wide opacity-50">{@label}</span>
      <span class="text-base font-semibold truncate">{@name || "—"}</span>
      <span :if={@rank} class="text-xs opacity-70">{@rank}</span>
      <span :for={commander <- @commanders} class="text-xs opacity-70 truncate">
        ⌬ {commander}
      </span>
    </div>
    """
  end

  @doc """
  Build a display-ready view model from a `live_match:updates` tick
  payload. `nil` payload → inactive (card hidden).
  """
  @spec view_model(map() | nil) :: %{
          active?: boolean(),
          opponent_name: String.t() | nil,
          local_name: String.t() | nil,
          opponent_rank: String.t() | nil,
          local_rank: String.t() | nil,
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
      local_rank: nil,
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
        format_rank(
          Map.get(opponent, :ranking_class, 0),
          Map.get(opponent, :ranking_tier, 0),
          Map.get(opponent, :mythic_percentile, 0),
          Map.get(opponent, :mythic_placement, 0)
        ),
      local_rank:
        format_rank(
          Map.get(local, :ranking_class, 0),
          Map.get(local, :ranking_tier, 0),
          Map.get(local, :mythic_percentile, 0),
          Map.get(local, :mythic_placement, 0)
        ),
      game_number: if(game_number > 0, do: game_number, else: nil),
      local_commander_arena_ids: Map.get(local, :commander_grp_ids, []),
      opponent_commander_arena_ids: Map.get(opponent, :commander_grp_ids, [])
    }
  end

  @doc """
  Format a rank for display. Returns `nil` when no rank is available
  (class index 0 = None).

  - Sub-Mythic: `"Diamond 3"` (class + tier).
  - Mythic with placement > 0: `"Mythic #42"`.
  - Mythic with percentile > 0: `"Mythic 12%"`.
  - Mythic with neither: `"Mythic"`.
  """
  @spec format_rank(integer(), integer(), integer(), integer()) :: String.t() | nil
  def format_rank(0, _tier, _percentile, _placement), do: nil

  def format_rank(6, _tier, _percentile, placement) when placement > 0 do
    "Mythic ##{placement}"
  end

  def format_rank(6, _tier, percentile, _placement) when percentile > 0 do
    "Mythic #{percentile}%"
  end

  def format_rank(6, _tier, _percentile, _placement), do: "Mythic"

  def format_rank(class, tier, _percentile, _placement)
      when class in 1..5 and is_integer(tier) do
    label = elem(@rank_class_labels, class)

    if tier > 0 do
      "#{label} #{tier}"
    else
      label
    end
  end

  def format_rank(_class, _tier, _percentile, _placement), do: nil

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
