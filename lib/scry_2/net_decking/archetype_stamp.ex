defmodule Scry2.NetDecking.ArchetypeStamp do
  @moduledoc """
  The classified-archetype columns for a netdeck row, computed from the
  Metagame vocabulary: `archetype_name` (display name, variant-refined),
  `archetype_variant`, `archetype_fallback`.

  Standard-only — the archetype vocabulary covers no other format yet,
  so anything else stamps nil. `:unknown` classifications stamp nil too;
  the catalog then falls back to its synthetic `color · hero` label.
  """

  alias Scry2.Metagame
  alias Scry2.Metagame.Classification

  @type t :: %{
          archetype_name: String.t() | nil,
          archetype_variant: String.t() | nil,
          archetype_fallback: boolean()
        }

  @spec attrs(map() | nil, map() | nil, String.t() | nil) :: t()
  def attrs(main_deck, sideboard, "Standard") do
    case Metagame.classify(main_deck, sideboard, "Standard") do
      %Classification{} = classification ->
        %{
          archetype_name: classification.name,
          archetype_variant: classification.variant,
          archetype_fallback: classification.fallback?
        }

      :unknown ->
        unclassified()
    end
  end

  def attrs(_main_deck, _sideboard, _format), do: unclassified()

  defp unclassified do
    %{archetype_name: nil, archetype_variant: nil, archetype_fallback: false}
  end
end
