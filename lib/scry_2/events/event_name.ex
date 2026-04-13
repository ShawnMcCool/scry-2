defmodule Scry2.Events.EventName do
  @moduledoc """
  Parses MTGA event name strings into structured components.

  MTGA event names encode game mode, optional set code, optional date stamp,
  and sometimes a wrapper event (like Midweek Magic) in underscore-delimited
  segments. This module decomposes them so downstream code never has to
  string-match on raw event names.

  Examples:

      iex> EventName.parse("QuickDraft_FDN_20260323")
      %EventName{format: "Quick Draft", format_type: "Limited", set_code: "FDN", ...}

      iex> EventName.parse("MWM_TMT_BotDraft_20260407")
      %EventName{format: "Midweek Magic Bot Draft", set_code: "TMT", wrapper: "Midweek Magic", ...}

      iex> EventName.parse("Traditional_Ladder")
      %EventName{format: "Ranked BO3", format_type: "Traditional", ...}

  ## Struct Fields

    - `raw` — the original event_name string
    - `format` — human-readable format label (e.g. "Midweek Magic Bot Draft")
    - `format_type` — "Limited", "Constructed", "Traditional", or nil
    - `wrapper` — wrapper event label (e.g. "Midweek Magic") or nil
    - `set_code` — 3-letter set code (e.g. "FDN") or nil
  """

  @enforce_keys [:raw]
  defstruct [:raw, :format, :format_type, :wrapper, :set_code]

  @type t :: %__MODULE__{
          raw: String.t() | nil,
          format: String.t() | nil,
          format_type: String.t() | nil,
          wrapper: String.t() | nil,
          set_code: String.t() | nil
        }

  # Known wrapper prefixes that wrap another game mode.
  @wrappers %{"MWM" => "Midweek Magic"}

  # Known game mode segments that appear as a single underscore-delimited token.
  @modes %{
    "QuickDraft" => {"Quick Draft", "Limited"},
    "PremierDraft" => {"Premier Draft", "Limited"},
    "TradDraft" => {"Traditional Draft", "Limited"},
    "BotDraft" => {"Bot Draft", "Limited"},
    "CompDraft" => {"Comp Draft", "Limited"},
    "Sealed" => {"Sealed", "Limited"}
  }

  # Compound event names matched as full strings (after wrapper/date removal).
  # These contain underscores that are part of the name, not segment separators.
  @compound_modes %{
    "Traditional_Ladder" => {"Ranked BO3", "Traditional"},
    "Traditional_Play" => {"Play BO3", "Traditional"},
    "Ladder" => {"Ranked", "Constructed"},
    "Play" => {"Play", "Constructed"},
    "DirectGame" => {"Direct Challenge", "Constructed"},
    "DirectGameLimited" => {"Direct Challenge", "Limited"}
  }

  @doc """
  Parses an MTGA event name string into a structured `%EventName{}`.

  Returns a struct with all nil fields for nil input.
  """
  def parse(nil), do: %__MODULE__{raw: nil}

  def parse(event_name) when is_binary(event_name) do
    segments = String.split(event_name, "_")

    {wrapper, segments} = pop_wrapper(segments)
    {_date, segments} = pop_date(segments)

    remaining = Enum.join(segments, "_")

    {mode_label, format_type, set_code} = identify(remaining, segments)

    format = if wrapper, do: "#{wrapper} #{mode_label}", else: mode_label

    %__MODULE__{
      raw: event_name,
      format: format,
      format_type: format_type,
      wrapper: wrapper,
      set_code: set_code
    }
  end

  # ── Segment extraction ────────────────────────────────────────────────

  defp pop_wrapper([first | rest]) do
    case Map.get(@wrappers, first) do
      nil -> {nil, [first | rest]}
      label -> {label, rest}
    end
  end

  defp pop_wrapper([]), do: {nil, []}

  # Remove trailing 8-digit date stamp (e.g. "20260323").
  defp pop_date(segments) when length(segments) > 1 do
    last = List.last(segments)

    if String.match?(last, ~r/^\d{8}$/) do
      {last, Enum.drop(segments, -1)}
    else
      {nil, segments}
    end
  end

  defp pop_date(segments), do: {nil, segments}

  # ── Mode identification ───────────────────────────────────────────────

  # Compound mode keys sorted longest-first so "Traditional_Ladder" matches
  # before "Traditional" would (if it existed as a compound).
  @compound_keys @compound_modes |> Map.keys() |> Enum.sort_by(&(-String.length(&1)))

  # Try compound modes first (prefix match), then look for a known mode segment.
  defp identify(remaining, segments) do
    cond do
      match = Enum.find(@compound_keys, &String.starts_with?(remaining, &1)) ->
        {label, type} = Map.fetch!(@compound_modes, match)
        {label, type, nil}

      String.starts_with?(remaining, "Jump_In") ->
        {"Jump In!", "Limited", nil}

      true ->
        find_mode_segment(segments)
    end
  end

  # Scan segments for a known mode token; treat remaining uppercase 2-4 letter
  # segments as set codes.
  defp find_mode_segment(segments) do
    case Enum.split_with(segments, &Map.has_key?(@modes, &1)) do
      {[mode_key | _], rest} ->
        {label, type} = Map.fetch!(@modes, mode_key)
        {label, type, find_set_code(rest)}

      {[], _} ->
        # No known mode — strip set code segments from the label
        set_code = find_set_code(segments)
        label_segments = if set_code, do: segments -- [set_code], else: segments
        label = Enum.join(label_segments, "_")
        {label, nil, set_code}
    end
  end

  # A set code is a 2-4 uppercase letter segment that isn't a known wrapper.
  defp find_set_code(segments) do
    Enum.find(segments, fn segment ->
      String.match?(segment, ~r/^[A-Z]{2,4}$/) and not Map.has_key?(@wrappers, segment)
    end)
  end
end
