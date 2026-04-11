defmodule Scry2Web.SetupLive do
  @moduledoc """
  First-run setup tour LiveView.

  A narrated walkthrough that explains what Scry 2 is doing and surfaces
  failures early. Each step is informational by default; action controls
  (manual path input, retry buttons) only appear when a step has a
  genuine failure.

  State management lives in `Scry2.SetupFlow` and `Scry2.SetupFlow.State`
  (ADR-013 — thin LiveView over extracted pure logic). This module wires
  events and PubSub updates to the state struct.
  """
  use Scry2Web, :live_view

  alias Scry2.Cards
  alias Scry2.MtgaLogIngestion
  alias Scry2.SetupFlow
  alias Scry2.Topics
  alias Scry2Web.SetupLive.Steps

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Topics.subscribe(Topics.mtga_logs_events())
      Topics.subscribe(Topics.mtga_logs_status())
      Topics.subscribe(Topics.cards_updates())
    end

    {:ok,
     socket
     |> assign(:page_title, "Set up Scry 2")
     |> assign(:state, %SetupFlow.State{step: :welcome})
     |> assign(:raw_event_count, 0)
     |> assign(:lands17_count, 0)
     |> assign(:scryfall_count, 0)
     |> assign(:lands17_updated_at, nil)
     |> assign(:scryfall_updated_at, nil)}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    # DB queries live here (ADR-019 — mount is called twice). The setup
    # tour reads fresh counts on every mount/patch so the informational
    # steps always reflect current reality.
    state = SetupFlow.initial_state()
    timestamps = Cards.import_timestamps()

    {:noreply,
     socket
     |> assign(:state, merge_step(socket.assigns.state, state))
     |> assign(:raw_event_count, MtgaLogIngestion.count_all())
     |> assign(:lands17_count, Cards.count())
     |> assign(:scryfall_count, Cards.scryfall_count())
     |> assign(:lands17_updated_at, timestamps.lands17_updated_at)
     |> assign(:scryfall_updated_at, timestamps.scryfall_updated_at)}
  end

  # Preserves the user's current position in the tour while still picking
  # up updated detected_path / manual_path state from a re-initialized state.
  defp merge_step(%SetupFlow.State{} = current, %SetupFlow.State{} = fresh) do
    %{
      fresh
      | step: current.step,
        completed_steps: current.completed_steps,
        manual_path: current.manual_path,
        manual_path_error: current.manual_path_error
    }
  end

  @impl true
  def handle_event("next", _params, socket) do
    {:noreply, assign(socket, :state, SetupFlow.advance(socket.assigns.state))}
  end

  def handle_event("previous", _params, socket) do
    {:noreply, assign(socket, :state, SetupFlow.previous(socket.assigns.state))}
  end

  def handle_event("save_manual_path", %{"path" => path}, socket) do
    case SetupFlow.persist_player_log_path!(path) do
      {:ok, expanded} ->
        new_state = %{
          socket.assigns.state
          | detected_path: expanded,
            manual_path: path,
            manual_path_error: nil
        }

        {:noreply, assign(socket, :state, new_state)}

      {:error, :not_a_file} ->
        new_state = %{
          socket.assigns.state
          | manual_path: path,
            manual_path_error: "No file exists at that path. Double-check and try again."
        }

        {:noreply, assign(socket, :state, new_state)}
    end
  end

  def handle_event("finish", _params, socket) do
    :ok = SetupFlow.mark_completed!()
    {:noreply, push_navigate(socket, to: ~p"/")}
  end

  @impl true
  def handle_info({:event, _record}, socket) do
    # Live-update the raw event counter on the Verify step as events arrive.
    {:noreply, assign(socket, :raw_event_count, socket.assigns.raw_event_count + 1)}
  end

  def handle_info({:status, _status}, socket) do
    # Watcher status change — re-detect the path in case the user just
    # configured one via the Settings route or the manual input.
    state = SetupFlow.initial_state()
    new_state = %{socket.assigns.state | detected_path: state.detected_path}
    {:noreply, assign(socket, :state, new_state)}
  end

  def handle_info(:cards_refreshed, socket), do: refresh_card_assigns(socket)
  def handle_info(:arena_ids_backfilled, socket), do: refresh_card_assigns(socket)
  def handle_info(_other, socket), do: {:noreply, socket}

  defp refresh_card_assigns(socket) do
    timestamps = Cards.import_timestamps()

    {:noreply,
     socket
     |> assign(:lands17_count, Cards.count())
     |> assign(:scryfall_count, Cards.scryfall_count())
     |> assign(:lands17_updated_at, timestamps.lands17_updated_at)
     |> assign(:scryfall_updated_at, timestamps.scryfall_updated_at)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="min-h-screen flex items-center justify-center px-4 py-8">
      <div class="w-full max-w-2xl space-y-6">
        <header class="text-center">
          <h1 class="text-3xl font-semibold flex items-center justify-center gap-2">
            <.icon name="hero-eye" class="size-8 text-primary" /> Scry 2
          </h1>
          <p class="text-sm text-base-content/60 mt-1">First-run setup</p>
        </header>

        <.progress_indicator state={@state} />

        <section class="card bg-base-200">
          <div class="card-body">
            {render_step(assigns)}
          </div>
        </section>

        <div class="flex items-center justify-between">
          <button
            :if={@state.step != :welcome and @state.step != :done}
            phx-click="previous"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Back
          </button>
          <div :if={@state.step == :welcome or @state.step == :done}></div>

          <button
            :if={@state.step != :done}
            phx-click="next"
            class="btn btn-primary btn-sm"
          >
            {next_label(@state.step)}
            <.icon name="hero-arrow-right" class="size-4" />
          </button>
          <button :if={@state.step == :done} phx-click="finish" class="btn btn-primary btn-sm">
            Go to dashboard <.icon name="hero-arrow-right" class="size-4" />
          </button>
        </div>
      </div>
    </main>
    """
  end

  attr :state, SetupFlow.State, required: true

  defp progress_indicator(assigns) do
    ~H"""
    <div class="flex items-center justify-center gap-2 text-xs text-base-content/60">
      <span>Step {SetupFlow.State.step_number(@state.step)} of {SetupFlow.State.total_steps()}</span>
      <div class="flex gap-1">
        <div
          :for={step <- SetupFlow.State.steps()}
          class={dot_class(step, @state)}
        >
        </div>
      </div>
    </div>
    """
  end

  defp dot_class(step, %SetupFlow.State{step: current, completed_steps: completed}) do
    base = "size-2 rounded-full"

    cond do
      step == current -> "#{base} bg-primary"
      MapSet.member?(completed, step) -> "#{base} bg-success"
      true -> "#{base} bg-base-300"
    end
  end

  defp next_label(:welcome), do: "I've enabled Detailed Logs"
  defp next_label(:locate_log), do: "Continue"
  defp next_label(:card_status), do: "Continue"
  defp next_label(:verify_events), do: "Continue"
  defp next_label(_), do: "Continue"

  # Dispatch to the right step component based on current state.
  defp render_step(%{state: %SetupFlow.State{step: :welcome}} = assigns) do
    Steps.welcome_step(assigns)
  end

  defp render_step(%{state: %SetupFlow.State{step: :locate_log}} = assigns) do
    Steps.locate_log_step(assigns)
  end

  defp render_step(%{state: %SetupFlow.State{step: :card_status}} = assigns) do
    Steps.card_status_step(assigns)
  end

  defp render_step(%{state: %SetupFlow.State{step: :verify_events}} = assigns) do
    Steps.verify_events_step(assigns)
  end

  defp render_step(%{state: %SetupFlow.State{step: :done}} = assigns) do
    Steps.done_step(assigns)
  end
end
