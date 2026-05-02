defmodule Scry2Web.Components.PendingPacksCardTest do
  use ExUnit.Case, async: true

  alias Scry2Web.Components.PendingPacksCard

  describe "row_label/1" do
    test "renders the set code when present" do
      assert PendingPacksCard.row_label(%{set_code: "BLB"}) == "BLB"
    end

    test "falls back to 'Unknown set' when set_code is nil" do
      assert PendingPacksCard.row_label(%{set_code: nil}) == "Unknown set"
    end
  end
end
