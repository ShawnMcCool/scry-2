defmodule Scry2Web.InsightShowLive do
  @moduledoc """
  Per-insight explainer page at `/insights/:id`. Shows the rendered
  title and body, the full stats row, the underlying measurements
  table, and provenance: which detector produced it, when, and how
  fresh.

  Thin wiring per ADR-013. The page is intentionally text-and-table
  forward — the homepage tile is the showcase, this page is the proof.
  """

  use Scry2Web, :live_view

  alias Scry2.Insights
  alias Scry2.Insights.Insight
  alias Scry2.Showcase.Templates
  alias Scry2Web.Layouts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Insight")
     |> assign(:insight, nil)
     |> assign(:title, nil)
     |> assign(:body, nil)
     |> assign(:stats, [])}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    case Insights.get(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Insight not found.")
         |> push_navigate(to: ~p"/insights")}

      %Insight{} = insight ->
        {:noreply,
         socket
         |> assign(:insight, insight)
         |> assign(:title, Templates.render_title(insight))
         |> assign(:body, Templates.render_body(insight))
         |> assign(:stats, stats_list(insight.stats))}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.console_mount socket={@socket} />
    <Layouts.app
      flash={@flash}
      catch_up_status={@catch_up_status}
      sidebar_collapsed={@sidebar_collapsed}
      players={@players}
      active_player_id={@active_player_id}
      current_path={@player_scope_uri}
      nav_update={@nav_update}
    >
      <div class="space-y-6 max-w-3xl">
        <.link
          navigate={~p"/insights"}
          class="text-xs text-base-content/55 inline-flex items-center gap-1"
        >
          <.icon name="hero-arrow-long-left" class="size-3" /> all insights
        </.link>

        <header class="space-y-2">
          <div class="flex items-center gap-2">
            <span class="text-[10px] uppercase tracking-[0.10em] font-semibold text-primary/85">
              {@insight.detector}
            </span>
            <span
              :if={@insight.tier == 2}
              class="text-[9px] uppercase tracking-wide bg-warning/12 text-warning border border-warning/30 rounded px-1.5 py-0.5 font-mono"
            >
              tier 2
            </span>
          </div>
          <h1 class="text-2xl font-beleren leading-tight">{@title}</h1>
          <p :if={@body} class="text-sm text-base-content/75 leading-relaxed">{@body}</p>
        </header>

        <section
          :if={@stats != []}
          class="grid grid-cols-3 gap-3 rounded-lg bg-base-200/50 p-4 border border-base-content/10"
        >
          <div :for={stat <- @stats} class="flex flex-col">
            <span class="font-beleren text-xl text-base-content">{stat["num"]}</span>
            <span class="text-[10px] uppercase tracking-wide text-base-content/50">
              {stat["lbl"]}
            </span>
          </div>
        </section>

        <section class="space-y-2">
          <h2 class="text-sm uppercase tracking-wide text-base-content/55 font-semibold">
            Measurements
          </h2>
          <dl class="grid grid-cols-1 sm:grid-cols-2 gap-x-4 gap-y-2 text-xs text-base-content/75 border border-base-content/10 rounded-lg p-4 bg-base-200/30">
            <div
              :for={{k, v} <- Enum.sort(@insight.measurements || %{})}
              class="flex justify-between gap-3"
            >
              <dt class="font-mono text-base-content/55">{k}</dt>
              <dd class="font-mono">{format_value(v)}</dd>
            </div>
          </dl>
        </section>

        <section class="text-xs text-base-content/55 space-y-1">
          <div>Sample size: <span class="font-mono">n={@insight.sample_size}</span></div>
          <div :if={@insight.confidence}>
            Confidence: <span class="font-mono">{format_p_value(@insight.confidence)}</span>
          </div>
          <div>Computed: <span class="font-mono">{format_dt(@insight.computed_at)}</span></div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp stats_list(stats) when is_map(stats) do
    [stats["primary"], stats["secondary"], stats["tertiary"]]
    |> Enum.reject(&is_nil/1)
  end

  defp stats_list(_), do: []

  defp format_value(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 4)
  defp format_value(v) when is_integer(v), do: Integer.to_string(v)
  defp format_value(v) when is_binary(v), do: v
  defp format_value(v), do: inspect(v)

  defp format_p_value(p) when is_number(p) and p < 0.001, do: "p<0.001"
  defp format_p_value(p) when is_number(p), do: "p=" <> :erlang.float_to_binary(p, decimals: 3)
  defp format_p_value(_), do: "—"

  defp format_dt(nil), do: "—"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")
end
