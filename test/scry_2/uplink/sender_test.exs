defmodule Scry2.Uplink.SenderTest do
  use Scry2.DataCase

  alias Scry2.Events
  alias Scry2.TestFactory
  alias Scry2.Uplink
  alias Scry2.Uplink.Sender

  defmodule EchoTransport do
    @behaviour Scry2.Uplink.Transport

    @impl true
    def send_batch(%{test_pid: pid, reply: reply}, wire_events) do
      send(pid, {:sent_batch, wire_events})
      reply
    end
  end

  defp append_match_created(match_id) do
    raw = TestFactory.create_event_record(%{event_type: "MatchGameRoomStateChangedEvent"})
    Events.append!(TestFactory.build_match_created(%{mtga_match_id: match_id}), raw)
  end

  defp start_sender(reply) do
    start_supervised!(
      {Sender,
       name: :"sender_#{System.unique_integer([:positive])}",
       transport: EchoTransport,
       config: %{test_pid: self(), reply: reply},
       flush_interval_ms: 60_000,
       batch_limit: 500}
    )
  end

  describe "flush/1" do
    test "ships the unsent batch through the transport and advances the cursor on :ok" do
      append_match_created("m-1")
      append_match_created("m-2")
      sender = start_sender(:ok)

      assert {:sent, 2} = Sender.flush(sender)

      assert_receive {:sent_batch, wire_events}
      assert Enum.map(wire_events, & &1["payload"]["mtga_match_id"]) == ["m-1", "m-2"]
      assert {[], _} = Uplink.unsent_batch()
    end

    test "does not advance the cursor when the transport returns an error" do
      append_match_created("m-1")
      sender = start_sender({:error, :unreachable})

      assert {:error, :unreachable} = Sender.flush(sender)
      assert_receive {:sent_batch, _}

      {pending, _cursor} = Uplink.unsent_batch()
      assert Enum.map(pending, & &1["payload"]["mtga_match_id"]) == ["m-1"]
    end

    test "a retry after a failure re-sends and then advances on success" do
      append_match_created("m-1")
      fail_sender = start_sender({:error, :unreachable})
      assert {:error, :unreachable} = Sender.flush(fail_sender)
      assert_receive {:sent_batch, _}

      ok_sender = start_sender(:ok)
      assert {:sent, 1} = Sender.flush(ok_sender)
      assert_receive {:sent_batch, _}
      assert {[], _} = Uplink.unsent_batch()
    end

    test "does not call the transport when there is nothing to send" do
      sender = start_sender(:ok)

      assert :ok = Sender.flush(sender)
      refute_receive {:sent_batch, _}, 100
    end
  end
end
