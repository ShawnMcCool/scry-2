defmodule Scry2.Events.SilentMode do
  @moduledoc """
  Process-local flag that suppresses PubSub broadcasts from context
  upsert helpers during bulk rebuilds.

  Live writes (a single match completes, a single draft pick is made)
  fire `{:match_updated, _}` / `{:draft_updated, _}` / etc. on their
  topics so LiveViews and downstream projectors react in real time.
  Under a projector rebuild, those broadcasts cascade into a write
  storm: every replayed match upsert wakes `DraftProjection`, which
  re-counts wins/losses and writes a draft row, which broadcasts
  `:draft_updated`, which the listing LiveView re-renders, etc. Over a
  full rebuild that is thousands of redundant transactions per second
  hammering SQLite and Phoenix.PubSub at the same time as the
  rebuilding projector itself is doing per-event work.

  Wrapping the rebuild work in `with_silence/1` puts a flag on the
  current process; every context's broadcast helper checks `silent?/0`
  and skips the `Topics.broadcast/2` call. After the rebuild completes,
  each projector's `post_rebuild/0` callback is responsible for any
  derived state that would normally have been kept in sync via those
  broadcasts (see `Scry2.Drafts.DraftProjection.post_rebuild/0`).

  Process-local rather than global because each rebuild runs in its
  own task — concurrent live ingestion in other processes must keep
  broadcasting normally.
  """

  @flag {__MODULE__, :silent}

  @doc """
  Runs `fun` with the silent flag set. Always clears the flag, even
  when `fun` raises or throws.
  """
  @spec with_silence((-> result)) :: result when result: var
  def with_silence(fun) when is_function(fun, 0) do
    previous = Process.put(@flag, true)

    try do
      fun.()
    after
      if is_nil(previous), do: Process.delete(@flag), else: Process.put(@flag, previous)
    end
  end

  @doc "Returns true if broadcasts should currently be suppressed."
  @spec silent?() :: boolean()
  def silent?, do: Process.get(@flag, false) == true
end
