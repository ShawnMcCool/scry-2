defmodule Scry2.Service.Backend.Unmanaged do
  @moduledoc """
  Fallback backend for environments with no detectable supervisor —
  `mix phx.server`, `iex -S mix`, ad-hoc `mix run`, the test suite.

  Status reports active (we're running by definition); restart and stop
  are not supported. The UI surfaces a hint that the BEAM is running
  standalone so the user knows why the action buttons are hidden.
  """

  @behaviour Scry2.Service.Backend

  @impl true
  def name(_opts), do: "unmanaged"

  @impl true
  def capabilities, do: %{can_restart: false, can_stop: false, can_status: true}

  @impl true
  def state(_opts), do: %{backend: :unmanaged, active: true}

  @impl true
  def restart(_opts), do: :not_supported

  @impl true
  def stop(_opts), do: :not_supported
end
