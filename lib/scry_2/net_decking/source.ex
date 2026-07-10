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
          optional(:source_url) => String.t(),
          optional(:pilot) => String.t(),
          optional(:event_name) => String.t(),
          optional(:event_date) => Date.t(),
          optional(:placement) => pos_integer(),
          optional(:swiss_rank) => pos_integer(),
          optional(:field_size) => pos_integer(),
          optional(:wins) => non_neg_integer(),
          optional(:losses) => non_neg_integer()
        }

  @typedoc "One browsable event on a source's landing page (import browser)."
  @type event :: %{
          required(:name) => String.t(),
          required(:url) => String.t(),
          required(:date) => Date.t() | nil
        }

  @doc "Stable provenance label for this source (e.g. \"local\", \"mtgo\")."
  @callback source_name() :: String.t()

  @doc "Fetch the current set of decks from this source."
  @callback fetch() :: [raw_deck()]

  @doc """
  Formats this source can be browsed by in the import browser. `[]` means
  the source is not browsable (e.g. the local JSON feed) and the browser
  will not offer it.
  """
  @callback formats() :: [String.t()]

  @doc "Recent events for a format, newest first, from the source's landing page."
  @callback list_events(format :: String.t()) :: {:ok, [event()]} | {:error, term()}

  @doc "Every raw deck of one event, identified by its landing-page URL."
  @callback fetch_event(url :: String.t()) :: {:ok, [raw_deck()]} | {:error, term()}

  @optional_callbacks list_events: 1, fetch_event: 1
end
