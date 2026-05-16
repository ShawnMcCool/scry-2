defmodule Scry2.Events.CatchUpStatusTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.CatchUpStatus

  defp status(name, watermark, max_event_id) do
    %{
      name: name,
      watermark: watermark,
      max_event_id: max_event_id,
      caught_up: watermark >= max_event_id
    }
  end

  describe "compute/1" do
    test "everything caught up — banner hidden, no projectors listed" do
      result =
        CatchUpStatus.compute([
          status("Matches", 1_000, 1_000),
          status("Drafts", 1_000, 1_000)
        ])

      assert result.caught_up
      assert result.lag == 0
      assert result.projectors_behind == []
    end

    test "single projector tiny lag below threshold — still treated as caught up" do
      # Lag of 5 is below the 50-event threshold for visible banner.
      result =
        CatchUpStatus.compute([
          status("Matches", 995, 1_000),
          status("Drafts", 1_000, 1_000)
        ])

      assert result.caught_up
      assert result.lag == 5
      assert result.projectors_behind == [{"Matches", 5}]
    end

    test "aggregate lag above threshold — banner shown" do
      result =
        CatchUpStatus.compute([
          status("Matches", 9_000, 10_000),
          status("Drafts", 9_500, 10_000),
          status("Ranks", 10_000, 10_000)
        ])

      refute result.caught_up
      assert result.lag == 1_500
      assert result.projectors_behind == [{"Matches", 1_000}, {"Drafts", 500}]
    end

    test "negative diffs (watermark briefly past max) clamp to 0" do
      # Status snapshots aren't transactional — a projector can report a
      # watermark a few events past max_event_id between writes. Don't
      # blow up; treat as 0 lag.
      result =
        CatchUpStatus.compute([
          status("Matches", 1_050, 1_000)
        ])

      assert result.caught_up
      assert result.lag == 0
      assert result.projectors_behind == []
    end

    test "projectors_behind is ordered most-behind first" do
      result =
        CatchUpStatus.compute([
          status("Small", 9_990, 10_000),
          status("Large", 5_000, 10_000),
          status("Medium", 9_000, 10_000)
        ])

      refute result.caught_up

      assert [{"Large", 5_000}, {"Medium", 1_000}, {"Small", 10}] =
               result.projectors_behind
    end
  end

  describe "min_visible_lag/0" do
    test "is a positive integer (threshold sanity)" do
      assert is_integer(CatchUpStatus.min_visible_lag())
      assert CatchUpStatus.min_visible_lag() > 0
    end
  end
end
