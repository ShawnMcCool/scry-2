defmodule Scry2.Events.ProjectorResilienceTest do
  @moduledoc """
  Verifies the Projector macro's per-event handlers survive the three Erlang
  exit kinds (`:error`, `:exit`, `:throw`). Without the `catch` clauses, a
  process exit raised mid-projection (e.g. a DBConnection checkout timeout
  under bulk load) escapes `rescue` and crashes the GenServer. Repeated
  restarts then cascade up the supervision tree and bring down the BEAM —
  the failure mode that v0.25.4 exhibited under prod reingest.
  """
  use Scry2.DataCase, async: false

  alias Scry2.Events
  alias Scry2.Events.EventRecord

  # Toggle that controls how many calls to `project/1` have been made,
  # which is then used by FlakyProjector to pick a failure mode per call.
  @counter_key {__MODULE__, :counter}

  # Test-only projector that uses a real slug (`session_started`) so
  # rehydrate works, but its project/1 cycles through the three failure
  # modes plus a clean :ok per call. Verifies the wrapper's catch clauses.
  defmodule FlakyProjector do
    use Scry2.Events.Projector,
      claimed_slugs: ~w(session_started),
      projection_tables: []

    defp project(_event) do
      next = :persistent_term.get({Scry2.Events.ProjectorResilienceTest, :counter}, 0) + 1
      :persistent_term.put({Scry2.Events.ProjectorResilienceTest, :counter}, next)

      case rem(next, 4) do
        1 -> raise "bang from event #{next}"
        2 -> throw({:nope, next})
        3 -> exit({:oops, next})
        0 -> :ok
      end
    end
  end

  defp insert_session_event!(sequence) do
    payload = %{
      "client_id" => "TEST_USER_#{sequence}",
      "screen_name" => "TestUser#{sequence}",
      "session_id" => "session-#{sequence}",
      "occurred_at" => "2026-04-28T00:00:00Z"
    }

    # Use Events.append! through the wire format — but we don't have a
    # raw event id here. Insert directly via Ecto since we own the test DB.
    %EventRecord{}
    |> Ecto.Changeset.cast(
      %{
        event_type: "session_started",
        payload: payload,
        sequence: sequence,
        mtga_timestamp: ~U[2026-04-28 00:00:00Z],
        inserted_at: DateTime.utc_now(:second)
      },
      [:event_type, :payload, :sequence, :mtga_timestamp, :inserted_at]
    )
    |> Repo.insert!()
  end

  setup do
    :persistent_term.put(@counter_key, 0)
    Repo.delete_all(EventRecord)
    on_exit(fn -> :persistent_term.erase(@counter_key) end)
    :ok
  end

  test "rebuild!/1 survives raise / throw / exit across many events" do
    # 8 events → projector cycles raise, throw, exit, ok, raise, throw, exit, ok
    Enum.each(1..8, &insert_session_event!/1)

    # Without the new `catch` clauses on `:exit` and `:throw`, those would
    # propagate and either kill the test process or trip an unhandled-exit.
    assert :ok = FlakyProjector.rebuild!()

    max_id = Repo.aggregate(EventRecord, :max, :id)
    wm = Events.get_watermark(FlakyProjector.projector_name())
    assert wm == max_id, "expected watermark #{wm} to equal max event id #{max_id}"
  end

  test "catch_up!/1 survives raise / throw / exit across many events" do
    Enum.each(1..8, &insert_session_event!/1)

    assert :ok = FlakyProjector.catch_up!()

    max_id = Repo.aggregate(EventRecord, :max, :id)
    wm = Events.get_watermark(FlakyProjector.projector_name())
    assert wm == max_id
  end
end
