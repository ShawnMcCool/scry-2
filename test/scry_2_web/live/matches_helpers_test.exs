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
end
