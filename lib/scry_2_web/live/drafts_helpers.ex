defmodule Scry2Web.DraftsHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.DraftsLive`. Extracted per ADR-013.
  """

  @doc """
  The arena_ids a pick's pack section should display: the pack contents
  when the log captured them, otherwise just the picked card (older logs
  lack pack contents), otherwise nothing.
  """
  @spec pack_display_ids(map()) :: [integer()]
  def pack_display_ids(%{pack_arena_ids: %{"cards" => [_ | _] = ids}}), do: ids
  def pack_display_ids(%{picked_arena_id: picked}) when is_integer(picked), do: [picked]
  def pack_display_ids(_pick), do: []

  @doc "True when the draft has the maximum wins (trophy run)."
  @spec trophy?(map()) :: boolean()
  def trophy?(%{wins: 7}), do: true
  def trophy?(_), do: false

  @doc "Win rate as a float 0.0–1.0, or nil when no games played."
  @spec win_rate(map()) :: float() | nil
  def win_rate(%{wins: wins, losses: losses})
      when is_integer(wins) and is_integer(losses) and wins + losses > 0 do
    wins / (wins + losses)
  end

  def win_rate(_), do: nil

  @doc "Human-readable format label."
  @spec format_label(String.t() | nil) :: String.t()
  def format_label("quick_draft"), do: "Quick Draft"
  def format_label("premier_draft"), do: "Premier Draft"
  def format_label("traditional_draft"), do: "Traditional Draft"
  def format_label(nil), do: "—"

  def format_label(other),
    do: other |> String.split("_") |> Enum.map(&String.capitalize/1) |> Enum.join(" ")

  @doc "Tailwind CSS color class based on win rate."
  @spec record_color_class(map()) :: String.t()
  def record_color_class(draft) do
    case win_rate(draft) do
      nil -> "text-base-content/50"
      rate -> "text-#{win_rate_color(rate)}"
    end
  end

  @doc "Returns the daisyUI color name (success/warning/error) for a win rate float."
  @spec win_rate_color(float()) :: String.t()
  def win_rate_color(rate) when rate >= 0.55, do: "success"
  def win_rate_color(rate) when rate >= 0.40, do: "warning"
  def win_rate_color(_), do: "error"

  @doc "Format a win-loss record for display."
  @spec win_loss_label(integer() | nil, integer() | nil) :: String.t()
  def win_loss_label(wins, losses), do: "#{wins || 0}–#{losses || 0}"

  @doc "Returns a human label for draft completion status."
  @spec draft_status_label(map()) :: String.t()
  def draft_status_label(%{completed_at: nil}), do: "In progress"
  def draft_status_label(_draft), do: "Complete"

  # Private
end
