defmodule Scry2Web.MatchesHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.MatchesHelpers, as: H

  describe "result_class/1 and result_label/1" do
    test "map true/false/nil to matching daisyUI classes and labels" do
      assert H.result_class(true) == "badge-success"
      assert H.result_class(false) == "badge-error"
      assert H.result_class(nil) == "badge-ghost"

      assert H.result_label(true) == "Won"
      assert H.result_label(false) == "Lost"
      assert H.result_label(nil) == "—"
    end
  end

  describe "format_started_at/1" do
    test "returns — for nil" do
      assert H.format_started_at(nil) == "—"
    end

    test "formats a UTC datetime as YYYY-MM-DD HH:MM" do
      dt = ~U[2026-04-05 07:09:00Z]
      assert H.format_started_at(dt) == "2026-04-05 07:09"
    end
  end

  describe "format_label/1" do
    test "title-cases snake_case format strings" do
      assert H.format_label("premier_draft") == "Premier Draft"
      assert H.format_label("traditional_draft") == "Traditional Draft"
      assert H.format_label("sealed") == "Sealed"
    end

    test "returns — for nil" do
      assert H.format_label(nil) == "—"
    end
  end
end
