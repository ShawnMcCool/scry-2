defmodule Scry2.NetDecking.Source do
  @moduledoc """
  Behaviour for automated NetDecking corpus sources (deferred — no adapter
  ships in v1). An adapter returns raw decklists that are fed, unchanged,
  through `Scry2.NetDecking.IngestDecklist.run/1`. The manual paste path in
  the LiveView uses the same funnel, so adding an adapter touches nothing in
  Parse/Resolve/Dedup/Persist.
  """

  @typedoc "One raw deck ready for IngestDecklist.run/1."
  @type raw_deck :: %{
          required(:name) => String.t(),
          required(:source_name) => String.t(),
          required(:decklist_text) => String.t(),
          optional(:archetype) => String.t(),
          optional(:source_url) => String.t()
        }

  @doc "Fetch the current set of decks from this source."
  @callback fetch() :: [raw_deck()]
end
