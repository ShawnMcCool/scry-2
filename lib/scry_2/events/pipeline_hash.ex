defmodule Scry2.Events.PipelineHash do
  @moduledoc """
  Compile-time AST hashing for the translation pipeline.

  Hashes the source AST of all modules that affect domain event
  translation: IdentifyDomainEvents, EnrichEvents, SnapshotDiff,
  SnapshotConvert, IngestionState, and every domain event struct.

  A change to any of these modules produces a different hash,
  signaling that full reingestion is needed on startup. The hash
  is baked into the `.beam` file — zero file I/O at runtime.

  Whitespace and comments are stripped by `Code.string_to_quoted/1`,
  so formatting-only changes do not alter the hash.
  """

  # Translator-layer source files
  @translator_files [
    "lib/scry_2/events/identify_domain_events.ex",
    "lib/scry_2/events/enrich_events.ex",
    "lib/scry_2/events/snapshot_diff.ex",
    "lib/scry_2/events/snapshot_convert.ex",
    "lib/scry_2/events/ingestion_state.ex",
    "lib/scry_2/events/ingestion_state/session.ex",
    "lib/scry_2/events/ingestion_state/match.ex"
  ]

  # Domain event struct files — everything in category subdirectories.
  @event_struct_dirs ~w(match deck draft gameplay economy event progression session)
  @event_files Enum.flat_map(@event_struct_dirs, fn dir ->
                 Path.wildcard("lib/scry_2/events/#{dir}/*.ex")
               end)

  @all_files Enum.sort(@translator_files ++ @event_files)

  # Register each file as an external resource so Mix recompiles this
  # module when any of them change.
  for file <- @all_files do
    @external_resource file
  end

  @translator_hash @all_files
                   |> Enum.map(fn file ->
                     {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()
                     :erlang.phash2(ast)
                   end)
                   |> then(&:erlang.phash2/1)
                   |> Integer.to_string()

  @doc "Combined AST hash of all translator + domain event modules."
  def translator_hash, do: @translator_hash

  @doc "List of files included in the translator hash (for diagnostics)."
  def hashed_files, do: @all_files
end
