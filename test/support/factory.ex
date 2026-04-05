defmodule Scry2.TestFactory do
  @moduledoc """
  Factory helpers for tests.

  Two flavours, following the media-centaur / Scry2 convention:

    * `build_*/1` — plain structs with sensible defaults, no DB. Use for
      pure-function tests (async: true).
    * `create_*/1` — persists via the owning context, returns the loaded
      record. Use for resource tests (`use Scry2.DataCase`).

  Attrs can be either a keyword list or a map.
  """

  alias Scry2.Cards
  alias Scry2.Cards.{Card, Set}
  alias Scry2.Drafts
  alias Scry2.Drafts.{Draft, Pick}
  alias Scry2.Matches
  alias Scry2.Matches.{DeckSubmission, Game, Match}
  alias Scry2.MtgaLogs
  alias Scry2.MtgaLogs.{Cursor, EventRecord}

  # ── build_* (no DB) ─────────────────────────────────────────────────────

  def build_set(attrs \\ %{}) do
    defaults = %{code: "TST", name: "Test Set", released_at: ~D[2026-01-01]}
    struct(Set, Map.merge(defaults, Map.new(attrs)))
  end

  def build_card(attrs \\ %{}) do
    defaults = %{
      # arena_id stays nil by default — tests that care about it set it
      # explicitly. It's nullable in the schema (backfilled from Scryfall
      # after the lands17 import) and the unique index is partial
      # (WHERE arena_id IS NOT NULL), so multiple nil rows don't collide.
      arena_id: nil,
      lands17_id: 12_345,
      name: "Test Card",
      rarity: "common",
      color_identity: "W",
      mana_value: 1,
      types: "Creature",
      is_booster: true,
      raw: %{}
    }

    struct(Card, Map.merge(defaults, Map.new(attrs)))
  end

  def build_match(attrs \\ %{}) do
    defaults = %{
      mtga_match_id: "test-match-" <> random_suffix(),
      event_name: "PremierDraft_LCI_20260401",
      format: "premier_draft",
      started_at: DateTime.utc_now(:second),
      num_games: 2,
      won: true
    }

    struct(Match, Map.merge(defaults, Map.new(attrs)))
  end

  def build_game(attrs \\ %{}) do
    defaults = %{
      game_number: 1,
      on_play: true,
      num_mulligans: 0,
      num_turns: 9,
      won: true,
      main_colors: "WU"
    }

    struct(Game, Map.merge(defaults, Map.new(attrs)))
  end

  def build_deck_submission(attrs \\ %{}) do
    defaults = %{
      mtga_deck_id: "test-deck-" <> random_suffix(),
      name: "Test Deck",
      main_deck: %{"cards" => [%{"arena_id" => 91_234, "count" => 4}]},
      sideboard: %{"cards" => []},
      submitted_at: DateTime.utc_now(:second)
    }

    struct(DeckSubmission, Map.merge(defaults, Map.new(attrs)))
  end

  def build_draft(attrs \\ %{}) do
    defaults = %{
      mtga_draft_id: "test-draft-" <> random_suffix(),
      event_name: "PremierDraft_LCI_20260401",
      format: "premier",
      set_code: "LCI",
      started_at: DateTime.utc_now(:second)
    }

    struct(Draft, Map.merge(defaults, Map.new(attrs)))
  end

  def build_pick(attrs \\ %{}) do
    defaults = %{
      pack_number: 1,
      pick_number: 1,
      picked_arena_id: 91_234,
      pack_arena_ids: %{"cards" => [91_234, 91_235]},
      pool_arena_ids: %{"cards" => []},
      picked_at: DateTime.utc_now(:second)
    }

    struct(Pick, Map.merge(defaults, Map.new(attrs)))
  end

  def build_event_record(attrs \\ %{}) do
    defaults = %{
      event_type: "MatchStart",
      mtga_timestamp: DateTime.utc_now(:second),
      file_offset: 0,
      source_file: "/tmp/fixture-player.log",
      raw_json: ~s({"event":"MatchStart"}),
      processed: false,
      inserted_at: DateTime.utc_now(:second)
    }

    struct(EventRecord, Map.merge(defaults, Map.new(attrs)))
  end

  # ── create_* (persisted) ────────────────────────────────────────────────

  def create_set(attrs \\ %{}) do
    attrs |> build_set() |> Map.from_struct() |> Cards.upsert_set!()
  end

  def create_card(attrs \\ %{}) do
    attrs = Map.new(attrs)
    # Make lands17_id unique per call to avoid test cross-contamination.
    attrs = Map.put_new(attrs, :lands17_id, :rand.uniform(1_000_000_000))
    attrs |> build_card() |> Map.from_struct() |> Map.drop([:__meta__]) |> Cards.upsert_card!()
  end

  def create_match(attrs \\ %{}) do
    attrs
    |> build_match()
    |> Map.from_struct()
    |> Map.drop([:__meta__, :games, :deck_submissions])
    |> Matches.upsert_match!()
  end

  def create_game(attrs \\ %{}) do
    match = attrs[:match] || attrs["match"] || create_match(%{})
    base = attrs |> Map.new() |> Map.drop([:match])

    build_game(base)
    |> Map.from_struct()
    |> Map.drop([:__meta__, :match])
    |> Map.put(:match_id, match.id)
    |> Matches.insert_game!()
  end

  def create_draft(attrs \\ %{}) do
    attrs
    |> build_draft()
    |> Map.from_struct()
    |> Map.drop([:__meta__, :picks])
    |> Drafts.upsert_draft!()
  end

  def create_pick(attrs \\ %{}) do
    draft = attrs[:draft] || attrs["draft"] || create_draft(%{})
    base = attrs |> Map.new() |> Map.drop([:draft])

    build_pick(base)
    |> Map.from_struct()
    |> Map.drop([:__meta__, :draft])
    |> Map.put(:draft_id, draft.id)
    |> Drafts.upsert_pick!()
  end

  def create_event_record(attrs \\ %{}) do
    attrs
    |> build_event_record()
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> MtgaLogs.insert_event!()
  end

  def create_cursor(attrs \\ %{}) do
    defaults = %{
      file_path: "/tmp/fixture-player-#{random_suffix()}.log",
      byte_offset: 0,
      last_read_at: DateTime.utc_now(:second)
    }

    attrs |> Map.new() |> then(&Map.merge(defaults, &1)) |> MtgaLogs.put_cursor!()
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp random_suffix, do: Integer.to_string(:rand.uniform(1_000_000_000), 36)

  # Silence unused-alias warnings for test support code.
  @compile {:no_warn_unused, [Cursor, EventRecord, DeckSubmission]}
end
