defmodule Scry2Web.SetupGate do
  @moduledoc """
  LiveView `on_mount` hook that redirects first-run users to `/setup`.

  Attached to the `:default` live_session in the router, so every live
  route except `/setup` itself is gated. Consults `Scry2.SetupFlow.required?/0`
  to decide whether to redirect.

  The hook halts the socket before PlayerScope or any other hook runs,
  preventing the destination LiveView from mounting on a half-configured
  system.
  """

  import Phoenix.LiveView, only: [redirect: 2]

  alias Scry2.SetupFlow

  def on_mount(:default, _params, _session, socket) do
    if SetupFlow.required?() do
      {:halt, redirect(socket, to: "/setup")}
    else
      {:cont, socket}
    end
  end
end
