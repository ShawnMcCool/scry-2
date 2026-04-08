defmodule Scry2.ProjectorCase do
  @moduledoc """
  Test helpers for projector tests.

  Provides `project_events/2` which persists domain events and runs
  `rebuild!/0` in one call, and `match_scenario/2` which builds a
  complete match lifecycle (created → games → completed) from a
  compact description.

  ## Usage

      use Scry2.DataCase
      import Scry2.TestFactory
      import Scry2.ProjectorCase

      test "full match lifecycle" do
        player = create_player()

        events = match_scenario(player, won: true, games: [
          [game_number: 1, won: true, on_play: true, num_turns: 7],
          [game_number: 2, won: false, on_play: false, num_turns: 11]
        ])

        project_events(Scry2.Matches.UpdateFromEvent, events)

        match = Matches.get_by_mtga_id(events.match_id, player.id)
        assert match.won == true
      end
  """

  import Scry2.TestFactory

  @doc """
  Persists a list of domain events to the event store and runs the
  projector's `rebuild!/0`. Returns the list of persisted event records.

  Accepts a single event or a list. Also accepts a `%{events: [...]}` map
  returned by `match_scenario/2`.
  """
  def project_events(projector_module, %{events: events}) do
    project_events(projector_module, events)
  end

  def project_events(projector_module, events) when is_list(events) do
    records = Enum.map(events, &create_domain_event/1)
    projector_module.rebuild!()
    records
  end

  def project_events(projector_module, event) when is_struct(event) do
    project_events(projector_module, [event])
  end

  @doc """
  Builds a complete match lifecycle as a list of domain events.

  Returns `%{match_id: id, events: [event_structs]}`.

  ## Options

    * `:match_id` — override the auto-generated match id
    * `:event_name` — event name (default "PremierDraft_FDN_20260401")
    * `:opponent` — opponent screen name (default "TestOpponent")
    * `:started_at` — match start time (default now)
    * `:won` — match result (required)
    * `:games` — list of game keyword lists, each with `:game_number`,
      `:won`, `:on_play`, `:num_turns`, `:num_mulligans` (defaults to 0)
    * `:deck` — keyword list with `:deck_id`, `:colors`, `:main_deck`
    * `:format` — format string (default "premier_draft")
    * `:format_type` — format type (default "limited")
    * `:player_rank` — rank string (default "Gold 1")
  """
  def match_scenario(player, opts) do
    opts = Keyword.new(opts)
    match_id = Keyword.get(opts, :match_id, "test-match-#{random_id()}")
    started_at = Keyword.get(opts, :started_at, DateTime.utc_now(:second))

    player_id = player.id

    common = %{player_id: player_id, mtga_match_id: match_id}

    created =
      build_match_created(
        Map.merge(common, %{
          event_name: Keyword.get(opts, :event_name, "PremierDraft_FDN_20260401"),
          opponent_screen_name: Keyword.get(opts, :opponent, "TestOpponent"),
          occurred_at: started_at,
          player_rank: Keyword.get(opts, :player_rank, "Gold 1"),
          format: Keyword.get(opts, :format, "premier_draft"),
          format_type: Keyword.get(opts, :format_type, "limited")
        })
      )

    games =
      opts
      |> Keyword.get(:games, [])
      |> Enum.with_index(1)
      |> Enum.map(fn {game_opts, default_num} ->
        game_opts = Keyword.new(game_opts)

        build_game_completed(
          Map.merge(common, %{
            game_number: Keyword.get(game_opts, :game_number, default_num),
            won: Keyword.fetch!(game_opts, :won),
            on_play: Keyword.get(game_opts, :on_play),
            num_turns: Keyword.get(game_opts, :num_turns, 8),
            num_mulligans: Keyword.get(game_opts, :num_mulligans, 0),
            occurred_at: DateTime.add(started_at, default_num * 300, :second)
          })
        )
      end)

    deck_events =
      case Keyword.get(opts, :deck) do
        nil ->
          []

        deck_opts ->
          deck_opts = Keyword.new(deck_opts)

          [
            build_deck_submitted(
              Map.merge(common, %{
                mtga_deck_id: Keyword.get(deck_opts, :deck_id, "test-deck-#{random_id()}"),
                deck_colors: Keyword.get(deck_opts, :colors, "WU"),
                main_deck:
                  Keyword.get(deck_opts, :main_deck, [%{"arena_id" => 91_234, "count" => 4}]),
                occurred_at: started_at
              })
            )
          ]
      end

    num_games = length(games)

    completed =
      if Keyword.get(opts, :won) != nil do
        [
          build_match_completed(
            Map.merge(common, %{
              won: Keyword.fetch!(opts, :won),
              num_games: num_games,
              occurred_at: DateTime.add(started_at, (num_games + 1) * 300, :second)
            })
          )
        ]
      else
        []
      end

    %{
      match_id: match_id,
      events: [created] ++ deck_events ++ games ++ completed
    }
  end

  defp random_id, do: Integer.to_string(System.unique_integer([:positive]), 36)
end
