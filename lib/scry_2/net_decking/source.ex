defmodule Scry2.NetDecking.Source do
  @moduledoc """
  Behaviour for automated NetDecking corpus sources. An adapter returns raw
  decklists that are fed, unchanged, through
  `Scry2.NetDecking.IngestDecklist.run/1`. The manual paste path in the
  LiveView uses the same funnel, so adding an adapter touches nothing in
  Parse/Resolve/Dedup/Persist.

  Shipped adapters (ADR-040): `Sources.LocalJsonSource` (canonical out-of-band
  feed) and `Sources.MtgoSource` (mtgo.com Standard). `Scry2.NetDecking.
  IngestSource` runs one source through the funnel; `Scry2.Workers.
  PeriodicallyFetchNetdecks` schedules the enabled sources daily.

  A source declares its provenance once via `source_name/0`; `IngestSource`
  stamps it onto every deck before persisting. `raw_deck` therefore describes
  the *deck* (name, list, archetype, per-deck `source_url`), not its origin —
  the source identity lives behind its owner, the source.
  """

  @typedoc "One raw deck ready for IngestSource to stamp + run through the funnel."
  @type raw_deck :: %{
          required(:name) => String.t(),
          required(:decklist_text) => String.t(),
          optional(:archetype) => String.t(),
          optional(:source_url) => String.t()
        }

  @doc "Stable provenance label for this source (e.g. \"local\", \"mtgo\")."
  @callback source_name() :: String.t()

  @doc "Fetch the current set of decks from this source."
  @callback fetch() :: [raw_deck()]
end
