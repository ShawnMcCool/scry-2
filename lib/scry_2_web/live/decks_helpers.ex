defmodule Scry2Web.DecksHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.DecksLive`. Extracted per ADR-013.

  Deck composition rendering (type/CMC grouping, mana curve, card stacks)
  lives in `Scry2Web.DeckRendering` — the deck rendering engine.
  This module keeps what is specific to the deck pages: record lines,
  version timeline helpers, and match display formatting.
  """

  alias Scry2Web.DeckRendering

  # ── Display formatting ─────────────────────────────────────────────

  @doc "Returns the deck_colors string for mana pip rendering."
  @spec deck_colors(map()) :: String.t()
  def deck_colors(%{deck_colors: colors}) when is_binary(colors), do: colors
  def deck_colors(_), do: ""

  @doc """
  A human-readable summary of a deck's match record, framed as a run result.
  Trophy framing applies only to draft decks (a 7-win cap is meaningful there;
  a constructed deck's tally is a lifetime count, not a run).

      iex> Scry2Web.DecksHelpers.deck_result_line(%Scry2.Decks.Deck{mtga_deck_id: "draft:x", bo1_wins: 7, bo1_losses: 2})
      "Trophy run — 7-2"
  """
  @spec deck_result_line(Scry2.Decks.Deck.t()) :: String.t()
  def deck_result_line(deck) do
    wins = (deck.bo1_wins || 0) + (deck.bo3_wins || 0)
    losses = (deck.bo1_losses || 0) + (deck.bo3_losses || 0)

    cond do
      wins == 0 and losses == 0 -> "No matches recorded yet"
      draft_deck?(deck) and wins >= 7 -> "Trophy run — #{wins}-#{losses}"
      true -> "Finished #{wins}-#{losses}"
    end
  end

  # Delegated to LiveHelpers (imported via `use Scry2Web, :live_view`)
  defdelegate relative_time(dt), to: Scry2Web.LiveHelpers
  defdelegate format_date(dt), to: Scry2Web.LiveHelpers
  defdelegate win_rate_class(rate), to: Scry2Web.LiveHelpers
  defdelegate format_win_rate(rate), to: Scry2Web.LiveHelpers
  defdelegate record_str(wins, losses), to: Scry2Web.LiveHelpers

  defdelegate cumulative_winrate_series(points), to: Scry2Web.LiveHelpers

  # ── Version timeline helpers ────────────────────────────────────────

  @doc """
  Returns a human-readable datetime string like "April 10, 2026 — 1:01 PM".
  """
  @spec format_version_date(DateTime.t() | nil) :: String.t()
  def format_version_date(nil), do: "—"

  def format_version_date(dt) do
    date = DateTime.to_date(dt)
    month = month_name(date.month)
    hour = rem(if(dt.hour == 0, do: 12, else: dt.hour), 12)
    hour = if hour == 0, do: 12, else: hour
    ampm = if dt.hour < 12, do: "AM", else: "PM"
    "#{month} #{date.day}, #{date.year} — #{hour}:#{pad(dt.minute)} #{ampm}"
  end

  @doc """
  Computes mana curve data for a version's before/after comparison.
  Returns `[{cmc_label, before_count, after_count}]` for CMC 1–7+.

  `previous_version` is the preceding version (or nil for the initial version).
  `cards_by_arena_id` is needed to look up mana values.
  """
  @spec version_mana_curve_data(map(), map() | nil, map()) :: [{String.t(), integer(), integer()}]
  def version_mana_curve_data(version, previous_version, cards_by_arena_id) do
    after_curve = DeckRendering.mana_curve(version.main_deck, cards_by_arena_id)

    before_curve =
      if previous_version,
        do: DeckRendering.mana_curve(previous_version.main_deck, cards_by_arena_id),
        else: after_curve

    1..7
    |> Enum.map(fn mv ->
      label = if mv >= 7, do: "7+", else: "#{mv}"
      {label, Map.get(before_curve, mv, 0), Map.get(after_curve, mv, 0)}
    end)
  end

  @doc "Extracts arena_ids from a deck version's diff card lists."
  @spec diff_arena_ids(map()) :: [integer()]
  def diff_arena_ids(version) do
    [
      version.main_deck_added,
      version.main_deck_removed,
      version.sideboard_added,
      version.sideboard_removed
    ]
    |> Enum.flat_map(&DeckRendering.arena_ids/1)
  end

  @doc "Extracts arena_ids from a version's full deck snapshot."
  @spec version_arena_ids(map()) :: [integer()]
  def version_arena_ids(version) do
    Enum.flat_map([version.main_deck, version.sideboard], &DeckRendering.arena_ids/1)
  end

  # ── Match display helpers (delegated to LiveHelpers) ─────────────────

  defdelegate group_matches_by_date(matches), to: Scry2Web.LiveHelpers
  defdelegate humanize_event(event_name, deck_format), to: Scry2Web.LiveHelpers
  defdelegate format_game_results(game_results), to: Scry2Web.LiveHelpers
  defdelegate match_score(match), to: Scry2Web.LiveHelpers

  # ── Private ─────────────────────────────────────────────────────────

  defp draft_deck?(deck), do: String.starts_with?(deck.mtga_deck_id || "", "draft:")

  defp month_name(1), do: "January"
  defp month_name(2), do: "February"
  defp month_name(3), do: "March"
  defp month_name(4), do: "April"
  defp month_name(5), do: "May"
  defp month_name(6), do: "June"
  defp month_name(7), do: "July"
  defp month_name(8), do: "August"
  defp month_name(9), do: "September"
  defp month_name(10), do: "October"
  defp month_name(11), do: "November"
  defp month_name(12), do: "December"

  defp pad(n) when n < 10, do: "0#{n}"
  defp pad(n), do: "#{n}"
end
