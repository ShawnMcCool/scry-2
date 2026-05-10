defmodule Scry2.Insights.ComputeAllTest do
  # async: false because we subscribe to a global PubSub topic that
  # other tests would also broadcast on if run concurrently.
  use Scry2.DataCase, async: false

  alias Scry2.Insights
  alias Scry2.TestFactory
  alias Scry2.Topics

  describe "compute_all/0" do
    test "returns {:ok, %{computed: n}} and broadcasts even when nothing fires" do
      Topics.subscribe(Topics.insights_updates())

      assert {:ok, %{computed: 0}} = Insights.compute_all()
      assert_receive :insights_recomputed, 500
    end

    test "runs OnPlayVsOnDraw and persists when threshold is met" do
      for _ <- 1..30 do
        TestFactory.create_match(%{on_play: true, won: true})
      end

      assert {:ok, %{computed: count}} = Insights.compute_all()
      assert count >= 1

      [first | _] = Insights.list_active(:home)
      assert first.detector == "OnPlayVsOnDraw"
      assert is_nil(first.superseded_at)
      assert first.sample_size == 30
    end

    test "supersedes prior active rows on a second pass" do
      for _ <- 1..30, do: TestFactory.create_match(%{on_play: true, won: true})

      {:ok, _} = Insights.compute_all()
      [first] = Insights.list_active(:home)

      {:ok, _} = Insights.compute_all()

      [active] = Insights.list_active(:home)
      refute active.id == first.id
      assert is_nil(active.superseded_at)

      superseded = Insights.get(first.id)
      refute is_nil(superseded.superseded_at)
    end
  end
end
