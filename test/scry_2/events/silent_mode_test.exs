defmodule Scry2.Events.SilentModeTest do
  # Pure flag semantics are async-safe; the integration block flips into a
  # shared DB sandbox via Scry2.DataCase.setup_sandbox(%{async: false}).
  use ExUnit.Case, async: false

  alias Scry2.Events.SilentMode

  test "silent? defaults to false" do
    refute SilentMode.silent?()
  end

  test "with_silence sets the flag inside the function and clears it after" do
    refute SilentMode.silent?()

    result =
      SilentMode.with_silence(fn ->
        assert SilentMode.silent?()
        :returned
      end)

    assert result == :returned
    refute SilentMode.silent?()
  end

  test "clears the flag even when the function raises" do
    refute SilentMode.silent?()

    assert_raise RuntimeError, "boom", fn ->
      SilentMode.with_silence(fn ->
        assert SilentMode.silent?()
        raise "boom"
      end)
    end

    refute SilentMode.silent?()
  end

  test "nested with_silence preserves the flag through both layers and restores cleanly" do
    SilentMode.with_silence(fn ->
      assert SilentMode.silent?()

      SilentMode.with_silence(fn ->
        assert SilentMode.silent?()
      end)

      assert SilentMode.silent?()
    end)

    refute SilentMode.silent?()
  end

  test "the flag is process-local — sibling processes are unaffected" do
    parent = self()

    child =
      spawn(fn ->
        send(parent, {:before, SilentMode.silent?()})

        receive do
          :check ->
            send(parent, {:during, SilentMode.silent?()})
        end
      end)

    SilentMode.with_silence(fn ->
      send(child, :check)

      assert_receive {:before, false}
      assert_receive {:during, false}
    end)
  end

  describe "integration with context broadcast helpers" do
    alias Scry2.Topics

    setup do
      Scry2.DataCase.setup_sandbox(%{async: false})
      :ok
    end

    test "Matches.upsert_match! suppresses :match_updated when silent" do
      player = Scry2.TestFactory.create_player()
      Topics.subscribe(Topics.matches_updates())

      SilentMode.with_silence(fn ->
        Scry2.Matches.upsert_match!(%{
          player_id: player.id,
          mtga_match_id: "silent-#{System.unique_integer([:positive])}",
          event_name: "Traditional_Ladder",
          started_at: DateTime.utc_now(:second)
        })
      end)

      refute_receive {:match_updated, _}, 100
    end

    test "Matches.upsert_match! still broadcasts when not silent" do
      player = Scry2.TestFactory.create_player()
      Topics.subscribe(Topics.matches_updates())

      Scry2.Matches.upsert_match!(%{
        player_id: player.id,
        mtga_match_id: "loud-#{System.unique_integer([:positive])}",
        event_name: "Traditional_Ladder",
        started_at: DateTime.utc_now(:second)
      })

      assert_receive {:match_updated, _}, 200
    end
  end
end
