defmodule Scry2.Metagame.Classification do
  @moduledoc """
  The result of classifying a deck against the archetype vocabulary.

  `name` is the display name players know ("Izzet Prowess") — the
  variant name when a variant matched, the composed archetype name
  otherwise. `archetype` and `variant` carry the composed names of each
  level separately. `color` is the detected WUBRG color string.

  `confidence` grades the evidence:

  - `:exact` — classified from a complete decklist.
  - `:confirmed` — partial information, but every inclusion condition of
    the winning archetype was observed.
  - `:likely` — partial information, best unique candidate.

  Decks that match nothing classify as the bare atom `:unknown`, not a
  struct.
  """

  @enforce_keys [:name, :archetype, :fallback?, :confidence]
  defstruct [:name, :archetype, :variant, :fallback?, :color, :confidence]

  @type t :: %__MODULE__{
          name: String.t(),
          archetype: String.t(),
          variant: String.t() | nil,
          fallback?: boolean(),
          color: String.t() | nil,
          confidence: :exact | :confirmed | :likely
        }
end
