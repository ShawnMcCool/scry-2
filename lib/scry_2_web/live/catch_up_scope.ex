defmodule Scry2Web.CatchUpScope do
  @moduledoc """
  LiveView `on_mount` hook that exposes a projector-pipeline catch-up
  summary as `:catch_up_status` on the socket, so the layout can render
  a soft banner when a post-update or post-reingest absorption is
  visibly behind. Mirrors `Scry2Web.NavUpdateScope`'s pattern.

  ## Why it lives in an on_mount hook

  The banner needs to surface on every LiveView in the `:default`
  live_session (drafts, matches, cards, collection, ...) — anywhere the
  user might land after a self-update where the pipeline is still
  catching up. Threading the status through every LiveView's `mount` /
  `handle_info` would be duplication; one shared hook is the natural
  place.

  ## Assigns set

    * `:catch_up_status` — `Scry2.Events.CatchUpStatus.t()` (a map of
      `caught_up`, `lag`, `projectors_behind`). The banner component in
      `Layouts.app` reads this directly.

  ## Lifecycle

    * On dead mount (initial HTTP render): defaults to `caught_up: true`.
      No DB query — the dead render must stay cheap and `mount/3` is
      called twice (dead + live).
    * On live mount: subscribes to `domain:control` (operation lifecycle)
      and sends `:compute_catch_up_status` to itself so the actual
      computation runs *after* mount returns. Compute schedules its own
      follow-up refresh on a slow timer **only while lag exists** —
      once caught up, the timer stops scheduling itself, so caught-up
      sessions stay idle.

  ## Why NOT subscribe to `domain:events`

  During a big catch-up burst (e.g. retranslation of 400 k events),
  every domain event broadcast lands in every connected LiveView's
  mailbox. Subscribing here would multiply that fan-out per page. The
  timer + operation-lifecycle messages are enough to keep the banner
  fresh without that cost.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]

  alias Scry2.Events.{CatchUpStatus, ProjectorRegistry}
  alias Scry2.Topics

  # 5 seconds. Long enough that the banner doesn't flicker; short enough
  # that the user sees progress while the pipeline burns through a big
  # backlog. Only re-armed when status is not caught up.
  @poll_interval_ms 5_000

  @initial_status %{caught_up: true, lag: 0, projectors_behind: []}

  def on_mount(:default, _params, _session, socket) do
    socket =
      if connected?(socket) do
        Topics.subscribe(Topics.domain_control())
        send(self(), :compute_catch_up_status)
        socket
      else
        socket
      end

    socket =
      socket
      |> assign(:catch_up_status, @initial_status)
      |> attach_hook(:catch_up_status, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  # The hook's own messages are consumed (`:halt`) so they never reach the
  # host LiveView's `handle_info/2` (which doesn't pattern-match on them).
  # PubSub messages we just react to are passed through (`:cont`) — other
  # LiveViews on the same topic still need to see them.

  defp handle_info(:compute_catch_up_status, socket) do
    status = ProjectorRegistry.status_all() |> CatchUpStatus.compute()
    if not status.caught_up, do: schedule_refresh()
    {:halt, assign(socket, :catch_up_status, status)}
  end

  # Operations broadcasts during reingest / rebuild — recompute soon so
  # the banner reflects the new lag. Other LiveViews (e.g. OperationsLive)
  # are also subscribed and care, so leave their pipeline intact.
  defp handle_info({:operation_started, _type, _meta}, socket) do
    send(self(), :compute_catch_up_status)
    {:cont, socket}
  end

  defp handle_info({:operation_completed, _type}, socket) do
    send(self(), :compute_catch_up_status)
    {:cont, socket}
  end

  defp handle_info({:projector_rebuilt, _name}, socket) do
    send(self(), :compute_catch_up_status)
    {:cont, socket}
  end

  defp handle_info({:projector_caught_up, _name}, socket) do
    send(self(), :compute_catch_up_status)
    {:cont, socket}
  end

  defp handle_info(_other, socket), do: {:cont, socket}

  defp schedule_refresh do
    Process.send_after(self(), :compute_catch_up_status, @poll_interval_ms)
    :ok
  end
end
