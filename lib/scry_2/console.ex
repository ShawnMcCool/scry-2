defmodule Scry2.Console do
  @moduledoc """
  Bounded context for the in-browser log console: ring buffer, filter,
  and PubSub facade. All LiveViews and cross-context callers interact with
  the console through this module only — `RecentEntries`, `CaptureLogOutput`, and `Filter`
  are internal implementation details.

  Owns no database tables (it uses `Scry2.Settings` for filter + buffer-size
  persistence). Broadcasts to `Scry2.Topics.console_logs/0`.
  """

  alias Scry2.Console.{RecentEntries, Filter, DisplayHelpers}
  alias Scry2.Topics

  # ── reads ──────────────────────────────────────────────────────────────
  defdelegate snapshot(), to: RecentEntries
  defdelegate recent_entries(), to: RecentEntries, as: :recent
  defdelegate recent_entries(n), to: RecentEntries, as: :recent
  defdelegate get_filter(), to: RecentEntries
  defdelegate known_components(), to: DisplayHelpers

  # ── writes ─────────────────────────────────────────────────────────────
  defdelegate clear(), to: RecentEntries
  defdelegate resize(n), to: RecentEntries

  @doc "Updates the console filter. Persists asynchronously via the Buffer."
  @spec update_filter(Filter.t()) :: :ok
  def update_filter(%Filter{} = filter), do: RecentEntries.put_filter(filter)

  # ── pubsub ─────────────────────────────────────────────────────────────
  @doc "Subscribe the caller to console log events."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Topics.subscribe(Topics.console_logs())
  end
end
