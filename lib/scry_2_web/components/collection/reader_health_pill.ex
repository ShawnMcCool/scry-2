defmodule Scry2Web.Collection.ReaderHealthPill do
  @moduledoc """
  Small always-visible pill summarising the memory reader's steady-state
  health on `/collection`. Renders a `%Scry2.Collection.ReaderHealth{}`
  verdict struct as a soft, link-styled badge that deep-links to
  `/collection/diagnostics` for the full confidence-over-time chart.

  Tone uses soft variants per project memory: never solid bright fills.
  """

  use Phoenix.Component
  use Scry2Web, :verified_routes

  alias Scry2.Collection.ReaderHealth

  attr :health, ReaderHealth, required: true

  def reader_health_pill(assigns) do
    ~H"""
    <.link
      navigate={~p"/collection/diagnostics"}
      data-role="reader-health-pill"
      data-tone={@health.tone}
      data-status={@health.status}
      title={@health.detail}
      class={pill_classes(@health.tone)}
    >
      <span class={dot_classes(@health.tone)} aria-hidden="true"></span>
      <span>{@health.label}</span>
    </.link>
    """
  end

  defp pill_classes(tone) do
    [
      "inline-flex items-center gap-2 rounded-full px-3 py-1 text-xs font-medium no-underline transition-colors",
      tone_classes(tone)
    ]
  end

  defp tone_classes(:ok), do: "bg-success/10 text-success hover:bg-success/15"
  defp tone_classes(:warn), do: "bg-warning/10 text-warning hover:bg-warning/15"
  defp tone_classes(:error), do: "bg-error/10 text-error hover:bg-error/15"
  defp tone_classes(_), do: "bg-base-content/10 text-base-content/70 hover:bg-base-content/15"

  defp dot_classes(tone) do
    ["size-2 rounded-full", dot_color(tone)]
  end

  defp dot_color(:ok), do: "bg-success"
  defp dot_color(:warn), do: "bg-warning"
  defp dot_color(:error), do: "bg-error"
  defp dot_color(_), do: "bg-base-content/40"
end
