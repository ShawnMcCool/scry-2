defmodule Scry2.Collection.ReaderHealth do
  @moduledoc """
  Pure-function verdict over the latest collection snapshot + reader
  state, surfaced as the small always-visible reader-health pill on
  `/collection`.

  This is the steady-state view of "is the memory reader OK right now?"
  Transient errors (a refresh that just failed) are shown by the
  existing `last_error` alert in `ReaderStatus`; this module summarises
  what the most recent snapshot tells us.

  ## Statuses

    * `:no_snapshot` — no snapshots in the DB yet (e.g. fresh install,
      reader never run).
    * `:reader_disabled` — user has switched the reader off via
      `Collection.disable_reader!/0`. Wins over any snapshot state.
    * `:walker_recent` — last snapshot used the full Mono walker AND
      its `snapshot_ts` is within @recent_threshold seconds.
    * `:walker_stale` — last walker read is older than @recent_threshold.
    * `:fallback_in_use` — last snapshot used the slower fallback scanner
      (likely an offsets change in MTGA — see ADR-034 and the
      `mono-memory-reader` skill).

  The verdict struct carries display fields (`:label`, `:detail`,
  `:tone`) so the pill component is purely presentational.
  """

  alias Scry2.Collection.Snapshot

  @recent_threshold_seconds 30 * 60

  @type tone :: :ok | :warn | :error | :neutral
  @type status ::
          :no_snapshot
          | :reader_disabled
          | :walker_recent
          | :walker_stale
          | :fallback_in_use

  @type t :: %__MODULE__{
          status: status(),
          label: String.t(),
          detail: String.t(),
          tone: tone(),
          age_seconds: non_neg_integer() | nil
        }

  defstruct [:status, :label, :detail, :tone, :age_seconds]

  @doc """
  Compute the verdict from the latest snapshot + reader-enabled flag.

  Options:
    * `:snapshot` — the latest `%Snapshot{}` or `nil`
    * `:reader_enabled` — boolean
    * `:now` — `DateTime.t()` (test seam; defaults to `DateTime.utc_now/0`)
  """
  @spec compute(keyword()) :: t()
  def compute(opts) do
    snapshot = Keyword.get(opts, :snapshot)
    reader_enabled = Keyword.get(opts, :reader_enabled, true)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    classify(snapshot, reader_enabled, now)
  end

  defp classify(_snapshot, false, _now) do
    %__MODULE__{
      status: :reader_disabled,
      label: "Reader off",
      detail:
        "The memory reader is switched off. Enable it from the Collection page to capture snapshots from MTGA.",
      tone: :neutral,
      age_seconds: nil
    }
  end

  defp classify(nil, _enabled, _now) do
    %__MODULE__{
      status: :no_snapshot,
      label: "No reads yet",
      detail:
        "Scry2 has not yet read your collection from MTGA. Start MTGA and click Refresh now to capture the first snapshot.",
      tone: :neutral,
      age_seconds: nil
    }
  end

  defp classify(%Snapshot{snapshot_ts: ts, reader_confidence: "walker"}, _enabled, now) do
    age = DateTime.diff(now, ts, :second) |> max(0)

    if age <= @recent_threshold_seconds do
      %__MODULE__{
        status: :walker_recent,
        label: "Reader OK · #{format_age(age)}",
        detail:
          "Last read used the full memory walker. Collection, wallet, and wildcards are all fresh.",
        tone: :ok,
        age_seconds: age
      }
    else
      %__MODULE__{
        status: :walker_stale,
        label: "Reader stale · #{format_age(age)}",
        detail:
          "The last successful walker read is older than 30 minutes. Start MTGA and click Refresh now to capture a fresh snapshot.",
        tone: :warn,
        age_seconds: age
      }
    end
  end

  defp classify(
         %Snapshot{snapshot_ts: ts, reader_confidence: "fallback_scan"},
         _enabled,
         now
       ) do
    age = DateTime.diff(now, ts, :second) |> max(0)

    %__MODULE__{
      status: :fallback_in_use,
      label: "Fallback in use · #{format_age(age)}",
      detail:
        "The fast Mono walker can't navigate this MTGA build — Scry2 is using a slower fallback scanner. Your collection is still being read, but wallet, wildcards, and other walker-only data may be missing until Scry2 is updated.",
      tone: :warn,
      age_seconds: age
    }
  end

  @doc """
  Formats an age in seconds as a compact relative-time string.

  Examples:

      iex> Scry2.Collection.ReaderHealth.format_age(5)
      "5s ago"
      iex> Scry2.Collection.ReaderHealth.format_age(120)
      "2 min ago"
      iex> Scry2.Collection.ReaderHealth.format_age(3600)
      "1h ago"
      iex> Scry2.Collection.ReaderHealth.format_age(2 * 86_400)
      "2d ago"
  """
  @spec format_age(non_neg_integer()) :: String.t()
  def format_age(seconds) when is_integer(seconds) and seconds >= 0 do
    cond do
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end
end
