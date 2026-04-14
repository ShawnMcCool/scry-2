defmodule Scry2Web.DraftsHelpers do
  @moduledoc """
  Pure helper functions for `Scry2Web.DraftsLive`. Extracted per ADR-013.
  """

  @type_groups [
    {"Creatures", ~w(Creature)},
    {"Instants & Sorceries", ~w(Instant Sorcery)},
    {"Artifacts & Enchantments", ~w(Artifact Enchantment)},
    {"Lands", ~w(Land)},
    {"Other", []}
  ]

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

  @doc """
  Groups a list of arena_ids by card type using a lookup map of
  `%{arena_id => %{type_line: string}}`. Returns `[{label, [arena_id]}]`
  in canonical order, omitting empty groups.
  """
  @spec group_pool_by_type([integer()], map()) :: [{String.t(), [integer()]}]
  def group_pool_by_type(arena_ids, cards_by_arena_id) do
    classified =
      arena_ids
      |> Enum.flat_map(fn arena_id ->
        case Map.get(cards_by_arena_id, arena_id) do
          nil -> []
          card -> [{arena_id, classify_type(card.type_line)}]
        end
      end)

    @type_groups
    |> Enum.map(fn {label, _keywords} ->
      cards =
        classified
        |> Enum.filter(fn {_id, group} -> group == label end)
        |> Enum.map(&elem(&1, 0))

      {label, cards}
    end)
    |> Enum.reject(fn {_label, cards} -> cards == [] end)
  end

  @doc "Tailwind CSS color class based on win rate."
  @spec record_color_class(map()) :: String.t()
  def record_color_class(draft) do
    case win_rate(draft) do
      nil -> "text-base-content/50"
      rate when rate >= 0.55 -> "text-success"
      rate when rate >= 0.40 -> "text-warning"
      _ -> "text-error"
    end
  end

  @doc "Format a win-loss record for display."
  @spec win_loss_label(integer() | nil, integer() | nil) :: String.t()
  def win_loss_label(wins, losses), do: "#{wins || 0}–#{losses || 0}"

  @doc "Returns a human label for draft completion status."
  @spec draft_status_label(map()) :: String.t()
  def draft_status_label(%{completed_at: nil}), do: "In progress"
  def draft_status_label(_draft), do: "Complete"

  # Private

  defp classify_type(type_line) when is_binary(type_line) do
    cond do
      String.contains?(type_line, "Creature") ->
        "Creatures"

      String.contains?(type_line, "Instant") or String.contains?(type_line, "Sorcery") ->
        "Instants & Sorceries"

      String.contains?(type_line, "Artifact") or String.contains?(type_line, "Enchantment") ->
        "Artifacts & Enchantments"

      String.contains?(type_line, "Land") ->
        "Lands"

      true ->
        "Other"
    end
  end

  defp classify_type(_), do: "Other"
end
