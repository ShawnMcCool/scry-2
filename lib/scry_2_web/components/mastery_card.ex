defmodule Scry2Web.Components.MasteryCard do
  @moduledoc """
  Displays the player's current MTGA Mastery Pass — tier, XP-in-tier
  progress bar, mastery orbs, and season-end countdown — using the
  mastery fields on the latest `Scry2.Collection.Snapshot`.

  Used on `/economy`. Forecast logic is a separate component (see the
  follow-up plan).

  All formatting lives in `Scry2Web.Components.MasteryCard.Helpers`
  per ADR-013.
  """

  use Phoenix.Component

  import Scry2Web.CoreComponents

  alias Scry2Web.Components.MasteryCard.Helpers, as: H

  attr :snapshot, :any,
    required: true,
    doc:
      "Latest %Scry2.Collection.Snapshot{} or nil. Empty state shown when nil or mastery_tier is nil."

  attr :forecast, :any,
    default: nil,
    doc:
      "Result of `Scry2.Economy.Forecast.mastery_eta/2`. Map variant renders the projection line; atom variants and nil suppress it."

  attr :now, :any,
    default: nil,
    doc: "Override DateTime for testing; defaults to DateTime.utc_now/0."

  def mastery_card(assigns) do
    forecast_label = H.forecast_label(assigns[:forecast])

    assigns =
      assigns
      |> assign(:now, assigns[:now] || DateTime.utc_now())
      |> assign(:set_code, set_code(assigns[:snapshot]))
      |> assign(:forecast_label, forecast_label)

    ~H"""
    <section class="card bg-base-200 border border-base-300" data-role="mastery-card">
      <div class="card-body">
        <div class="flex items-baseline justify-between">
          <h2 class="card-title">Mastery Pass</h2>
          <span
            :if={has_mastery?(@snapshot) and @snapshot.mastery_season_ends_at != nil}
            class="text-xs text-base-content/60"
          >
            {H.season_end_countdown(@snapshot.mastery_season_ends_at, @now)}
          </span>
        </div>

        <%= if has_mastery?(@snapshot) do %>
          <div class="space-y-3 mt-3">
            <div class="flex items-center gap-3">
              <span class="text-3xl font-semibold tabular-nums">
                {H.format_tier(@snapshot.mastery_tier)}
              </span>
              <.set_icon
                :if={@set_code}
                code={@set_code}
                class="text-base-content/50"
              />
            </div>

            <div>
              <div class="flex items-baseline justify-between text-xs text-base-content/70">
                <span>{xp_in_tier_or_zero(@snapshot)} / {H.xp_per_tier()} XP toward next tier</span>
                <span>{H.xp_progress_percent(@snapshot.mastery_xp_in_tier)}%</span>
              </div>
              <div class="w-full bg-base-300 rounded-full h-2 mt-1">
                <div
                  class="bg-primary h-2 rounded-full"
                  style={"width: #{H.xp_progress_percent(@snapshot.mastery_xp_in_tier)}%"}
                />
              </div>
            </div>

            <div class="text-sm">
              <div class="text-xs text-base-content/60">Mastery orbs</div>
              <div class="tabular-nums">{@snapshot.mastery_orbs || 0}</div>
            </div>

            <p :if={@snapshot.mastery_season_name} class="text-xs text-base-content/60">
              Season {@snapshot.mastery_season_name}
            </p>

            <p
              :if={@forecast_label != ""}
              data-test="mastery-forecast"
              class="text-xs text-base-content/70 tabular-nums"
            >
              {@forecast_label}
            </p>
          </div>
        <% else %>
          <p class="text-sm text-base-content/60 mt-2">
            Mastery data not yet captured. Refresh your collection while MTGA is running.
          </p>
        <% end %>
      </div>
    </section>
    """
  end

  defp has_mastery?(nil), do: false
  defp has_mastery?(%{mastery_tier: nil}), do: false
  defp has_mastery?(%{mastery_tier: tier}) when is_integer(tier), do: true
  defp has_mastery?(_), do: false

  defp set_code(%{mastery_season_name: name}), do: H.set_code_from_season_name(name)
  defp set_code(_), do: nil

  defp xp_in_tier_or_zero(%{mastery_xp_in_tier: xp}) when is_integer(xp), do: xp
  defp xp_in_tier_or_zero(_), do: 0
end
