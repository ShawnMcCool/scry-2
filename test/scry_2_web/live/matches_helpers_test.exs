defmodule Scry2Web.MatchesHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.MatchesHelpers, as: H

  describe "result_letter/1 and result_letter_class/1" do
    test "map true/false/nil to letter and color class" do
      assert H.result_letter(true) == "W"
      assert H.result_letter(false) == "L"
      assert H.result_letter(nil) == "—"

      assert H.result_letter_class(true) == "text-emerald-400"
      assert H.result_letter_class(false) == "text-red-400"
      assert H.result_letter_class(nil) == "text-base-content/30"
    end
  end

  describe "format_match_datetime/1" do
    test "formats datetime as 'Mon DD · HH:MM'" do
      assert H.format_match_datetime(~U[2026-04-06 19:36:00Z]) == "Apr 06 · 19:36"
      assert H.format_match_datetime(nil) == "—"
    end
  end

  describe "game_score/2" do
    test "extracts W–L from game_results" do
      results = %{"results" => [%{"won" => true}, %{"won" => false}, %{"won" => true}]}
      assert H.game_score(results, true) == "2–1"
      assert H.game_score(nil, nil) == "—"
    end
  end

  describe "on_play_label/1" do
    test "maps boolean to Play/Draw/—" do
      assert H.on_play_label(true) == "Play"
      assert H.on_play_label(false) == "Draw"
      assert H.on_play_label(nil) == "—"
    end
  end
end
