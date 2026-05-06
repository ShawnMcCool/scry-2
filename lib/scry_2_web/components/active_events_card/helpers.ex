defmodule Scry2Web.Components.ActiveEventsCard.Helpers do
  @moduledoc """
  Pure formatting helpers for the active-events card. Extracted per
  ADR-013 — the card LiveView should be thin wiring; all branching /
  string-shaping lives here and is unit-tested.
  """

  @doc """
  Player-facing event label. Strips the noisy MTGA internal-name
  prefixes (`PremierDraft_`, `TradDraft_`, `Traditional_`,
  `Test_MID_`) and the trailing `_<set>` / `_YYYYMMDD` suffix where
  it doesn't carry meaning.

  Examples:
    * `"PremierDraft_SOS_20260421"` → `"Premier Draft SOS"`
    * `"DualColorPrecons"`           → `"Dual Color Precons"`
    * `"Play"`                        → `"Play"`
    * `nil`                           → `"Unknown event"`
  """
  @spec display_name(map()) :: String.t()
  def display_name(%{internal_event_name: nil}), do: "Unknown event"
  def display_name(%{internal_event_name: ""}), do: "Unknown event"

  def display_name(%{internal_event_name: name}) when is_binary(name) do
    name
    |> drop_trailing_yyyymmdd()
    |> humanize()
  end

  @doc "`\"4-1\"`-style record label. `\"—\"` when both counters are 0."
  @spec record_label(map()) :: String.t()
  def record_label(%{current_wins: 0, current_losses: 0}), do: "—"

  def record_label(%{current_wins: w, current_losses: l})
      when is_integer(w) and is_integer(l) do
    "#{w}–#{l}"
  end

  def record_label(_), do: "—"

  @doc """
  Format-name label. Falls back to a `format_type` string when the
  `format_name` slot is null (Limited events have null `Format`).
  """
  @spec format_label(map()) :: String.t()
  def format_label(%{format_name: name}) when is_binary(name) and name != "" do
    humanize(name)
  end

  def format_label(%{format_type: 1}), do: "Limited"
  def format_label(%{format_type: 2}), do: "Sealed"
  def format_label(%{format_type: 3}), do: "Constructed"
  def format_label(_), do: "—"

  @doc """
  Player-facing state label. The captured enum values are:
  `0` = available (filtered out upstream), `1` = entered/in progress,
  `3` = standing/always-on (Play, Ladder).
  """
  @spec state_label(map()) :: String.t()
  def state_label(%{current_event_state: 1}), do: "In progress"
  def state_label(%{current_event_state: 3}), do: "Standing"
  def state_label(%{current_event_state: state}), do: "State #{state}"

  @doc """
  daisyUI badge tone class for the state. Soft variants only — no
  bold solid fills (project UI rule).
  """
  @spec state_badge_class(map()) :: String.t()
  def state_badge_class(%{current_event_state: 1}), do: "badge-primary"
  def state_badge_class(%{current_event_state: 3}), do: "badge-info"
  def state_badge_class(_), do: "badge-ghost"

  @doc "Pluralised \"entry\" / \"entries\" for the count badge."
  @spec entry_word(non_neg_integer()) :: String.t()
  def entry_word(1), do: "entry"
  def entry_word(_), do: "entries"

  @doc "Friendly explanation for an error from `read_active_events/1`."
  @spec error_message(atom() | term()) :: String.t()
  def error_message(:mtga_not_running),
    do: "MTGA isn't running — start the game and check back."

  def error_message(:not_implemented),
    do: "Active-events reading isn't supported on this platform yet."

  def error_message(reason),
    do: "Couldn't read active events from MTGA (#{inspect(reason)})."

  # ── private ──────────────────────────────────────────────────────

  # Drops a trailing `_YYYYMMDD` segment if present.
  defp drop_trailing_yyyymmdd(name) do
    case Regex.run(~r/^(.*)_\d{8}$/, name) do
      [_, head] -> head
      _ -> name
    end
  end

  # Splits PascalCase / snake_case into space-separated words.
  defp humanize(""), do: ""

  defp humanize(s) do
    s
    |> String.replace("_", " ")
    |> String.replace(~r/([a-z])([A-Z])/, "\\1 \\2")
    |> String.split(" ", trim: true)
    |> Enum.join(" ")
  end
end
