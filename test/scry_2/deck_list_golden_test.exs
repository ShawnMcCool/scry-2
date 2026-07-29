defmodule Scry2.DeckListGoldenTest do
  @moduledoc """
  Golden compatibility tests for persisted deck identities.

  `composition_hash` values are stored on `decks_decks` rows and
  `composition_key` values are unique-indexed on `netdecking_decks`. The
  literals were captured from the pre-kernel implementations on 2026-07-29.
  If an assertion here fails, the change corrupts persisted identity — deck
  grouping fragments or corpus re-ingest duplicates rows. Fix the code,
  NEVER the literal (ADR-010 append-only discipline).
  """
  use ExUnit.Case, async: true

  alias Scry2.Decks
  alias Scry2.Decks.CompositionIdentity
  alias Scry2.NetDecking.CompositionKey

  # Duplicate arena_id 86_423 on purpose: composition_hash/1 must NOT sum
  # duplicates (raw sorted pairs), while canonical_pairs/2 MUST sum them.
  @main_deck_cards [
    %{"arena_id" => 86_423, "count" => 4},
    %{"arena_id" => 77_777, "count" => 2},
    %{"arena_id" => 86_423, "count" => 1},
    %{"arena_id" => 91_020, "count" => 24}
  ]

  @representatives %{77_777 => 86_423}

  @unresolved_cards [
    %{"name" => "  Fable of the Mirror-Breaker ", "count" => 2},
    %{"name" => "fable of the mirror-breaker", "count" => 1}
  ]

  test "composition_hash/1 — raw pairs, sorted, unsummed" do
    assert Decks.composition_hash(@main_deck_cards) == 59_084_888
  end

  test "composition_hash/1 — empty and unresolvable input is nil" do
    assert Decks.composition_hash([]) == nil
    assert Decks.composition_hash(nil) == nil
    assert Decks.composition_hash([%{"note" => "no arena_id"}]) == nil
  end

  test "canonical_pairs/2 — printings collapse onto representatives, counts summed" do
    assert CompositionIdentity.canonical_pairs(@main_deck_cards, @representatives) ==
             [{86_423, 7}, {91_020, 24}]
  end

  test "canonical composition hash — phash2 of summed pairs" do
    assert CompositionIdentity.hash(@main_deck_cards, @representatives) == 36_621_933
  end

  test "composition_key/2 — digest over resolved + case-folded unresolved lines" do
    assert CompositionKey.compute(@main_deck_cards, @unresolved_cards) ==
             "fd2b341062ac8de0a1c81ef7fc3bd22cd981c8d28e0aa8104be9e89f16911a6b"
  end

  test "composition_key/2 — empty composition is nil" do
    assert CompositionKey.compute([], []) == nil
  end

  test "canonical composition hash — empty list is nil" do
    assert CompositionIdentity.hash([], @representatives) == nil
  end

  test "composition_key/2 — unresolved-only composition" do
    assert CompositionKey.compute([], @unresolved_cards) ==
             "52b65ed98e3d96ca4e96c4a1f802e3c2405550ed026b45fc6f1dadbb777f059c"
  end
end
