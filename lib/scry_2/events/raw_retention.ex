defmodule Scry2.Events.RawRetention do
  @moduledoc """
  Retention policy for raw MTGA log events (`mtga_logs_events`) — see ADR-039.

  Raw events are a bounded, regenerable hedge: their only irreplaceable role
  is letting `Scry2.Events` re-extract new fields from MTGA's wire format
  when the translator changes (ADR-015). Projections never read raw; they
  rebuild from `domain_events` alone. So raw only needs to live as long as
  the retranslation horizon you actually care about.

  This module holds the **pure** retention decisions:

    * `coverage_verdict/1` — does surviving raw still cover the domain
      events a destructive rebuild is about to delete? Drives the seatbelt
      in `Scry2.Events` that refuses to wipe history it cannot reproduce.
    * `prune_cutoff/2` — given a retention window, what timestamp is the
      prune boundary? The dial is currently wired to "keep everything"
      (`raw_event_retention_days` defaults to `nil`); no caller deletes yet.

  The DB-touching coverage query lives in `Scry2.Events.raw_coverage_gap/0`,
  which delegates the decision here.
  """

  @doc """
  Reads the configured raw-event retention window in days.

  Returns `nil` (keep forever) unless `raw_event_retention_days` is set in
  config. This is the dial referenced by ADR-039 — present but, by default,
  off.
  """
  @spec retention_days() :: pos_integer() | non_neg_integer() | nil
  def retention_days, do: Scry2.Config.get(:raw_event_retention_days)

  @doc """
  Decides whether surviving raw covers the domain event log.

  `orphaned_count` is the number of domain events whose `mtga_source_id`
  points at a raw event that no longer exists. Zero means raw still covers
  every derived event (safe to wipe-and-rebuild); anything else is a gap.
  """
  @spec coverage_verdict(non_neg_integer()) :: :ok | {:gap, pos_integer()}
  def coverage_verdict(0), do: :ok

  def coverage_verdict(orphaned_count) when is_integer(orphaned_count) and orphaned_count > 0,
    do: {:gap, orphaned_count}

  @doc """
  Builds the error message raised when a destructive rebuild would delete
  domain events that surviving raw can no longer reproduce.
  """
  @spec coverage_error_message(pos_integer()) :: String.t()
  def coverage_error_message(orphaned_count) do
    """
    refusing to retranslate: #{orphaned_count} domain events have no surviving \
    raw source (raw events were pruned below their source ids). Deleting and \
    rebuilding from raw would permanently lose them. Pass force: true to \
    override only if you have already verified this is acceptable.\
    """
  end

  @doc """
  Computes the prune boundary for a retention window.

  `nil` days means keep forever (returns `nil`). A day count returns the
  `DateTime` that many days before `now`; raw events older than the cutoff
  would be eligible for pruning. Pure — `now` is passed in.

  No caller deletes based on this yet (ADR-039): the dial ships off.
  """
  @spec prune_cutoff(non_neg_integer() | nil, DateTime.t()) :: DateTime.t() | nil
  def prune_cutoff(nil, _now), do: nil

  def prune_cutoff(retention_days, %DateTime{} = now)
      when is_integer(retention_days) and retention_days >= 0 do
    DateTime.add(now, -retention_days * 86_400, :second)
  end
end
