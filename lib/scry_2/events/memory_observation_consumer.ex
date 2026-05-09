defmodule Scry2.Events.MemoryObservationConsumer do
  @moduledoc """
  Shared scaffold for stateless GenServers that subscribe to a single
  PubSub topic carrying memory-derived observations and react to each
  message by mutating downstream projections.

  Use it like this:

      defmodule Scry2.Matches.MergeOpponentObservation do
        use Scry2.Events.MemoryObservationConsumer,
            topic: Scry2.Topics.live_match_final()

        alias Scry2.LiveState.Snapshot
        alias Scry2.Matches

        @impl true
        def handle_info({:final, %Snapshot{} = snapshot}, state) do
          Matches.merge_opponent_observation(snapshot)
          {:noreply, state}
        end
      end

  The macro generates `start_link/1`, `init/1`, and a fallback
  `handle_info(_other, state)` clause, leaving each consumer to declare
  only the message shapes it actually cares about.

  Why a `use` macro instead of a behaviour: the contract here is "subscribe
  to topic X and own how messages are handled" — the topic is a piece of
  configuration, not a callback. A behaviour with `c:topic/0` would still
  require each module to copy `start_link`/`init`. The macro absorbs that
  scaffold.
  """

  defmacro __using__(opts) do
    topic = Keyword.fetch!(opts, :topic)

    quote location: :keep do
      use GenServer

      @doc false
      def start_link(opts \\ []) do
        {name, opts} = Keyword.pop(opts, :name, __MODULE__)
        GenServer.start_link(__MODULE__, opts, name: name)
      end

      @impl true
      def init(_opts) do
        Scry2.Topics.subscribe(unquote(topic))
        {:ok, %{}}
      end
    end
  end
end
