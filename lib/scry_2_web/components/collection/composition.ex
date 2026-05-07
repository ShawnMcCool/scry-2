defmodule Scry2Web.Collection.Composition do
  @moduledoc """
  Renders a `Scry2.Collection.Composition.t()` — rarity / colour / type
  breakdown of the player's collection.

  Each row is a horizontally-stacked bar where each segment's width is
  proportional to the bucket's `total_copies`.
  """

  use Phoenix.Component

  alias Scry2.Collection.Composition

  @rarity_order ~w(mythic rare uncommon common)
  @colour_order ~w(W U B R G M C)
  @type_order ~w(creature instant sorcery enchantment artifact planeswalker land battle)a

  @rarity_class %{
    "common" => "bg-base-content/30",
    "uncommon" => "bg-sky-500/70",
    "rare" => "bg-amber-500/70",
    "mythic" => "bg-rose-500/70"
  }

  @colour_class %{
    "W" => "bg-amber-100/60",
    "U" => "bg-sky-500/70",
    "B" => "bg-zinc-700",
    "R" => "bg-red-500/80",
    "G" => "bg-emerald-500/70",
    "M" => "bg-fuchsia-500/70",
    "C" => "bg-base-content/30"
  }

  attr :value, :any, required: true

  def composition(%{value: %Composition{total_copies: 0}} = assigns) do
    ~H"""
    <div class="card bg-base-200 border border-base-300 max-w-3xl" data-role="composition">
      <div class="card-body">
        <h2 class="card-title">Composition</h2>
        <p class="text-sm text-base-content/60">No collection data yet.</p>
      </div>
    </div>
    """
  end

  def composition(assigns) do
    assigns =
      assign(assigns,
        rarity_order: @rarity_order,
        colour_order: @colour_order,
        type_order: @type_order,
        rarity_class: @rarity_class,
        colour_class: @colour_class
      )

    ~H"""
    <div class="card bg-base-200 border border-base-300 max-w-3xl" data-role="composition">
      <div class="card-body space-y-4">
        <h2 class="card-title">Composition</h2>

        <.row
          label="By rarity"
          buckets={ordered(@value.by_rarity, @rarity_order)}
          total={@value.total_copies}
          tone_class={@rarity_class}
        />

        <.row
          label="By colour"
          buckets={ordered(@value.by_colour, @colour_order)}
          total={@value.total_copies}
          tone_class={@colour_class}
        />

        <.row
          label="By type"
          buckets={ordered_atom_keys(@value.by_type, @type_order)}
          total={@value.total_copies}
          tone_class={%{}}
        />
      </div>
    </div>
    """
  end

  defp ordered(map, order) do
    seen = MapSet.new(Map.keys(map))

    in_order = for key <- order, MapSet.member?(seen, key), do: {key, Map.fetch!(map, key)}
    rest = for {key, val} <- map, key not in order, do: {key, val}

    in_order ++ rest
  end

  defp ordered_atom_keys(map, order) do
    seen = MapSet.new(Map.keys(map))
    in_order = for key <- order, MapSet.member?(seen, key), do: {key, Map.fetch!(map, key)}
    rest = for {key, val} <- map, key not in order, do: {key, val}
    in_order ++ rest
  end

  attr :label, :string, required: true
  attr :buckets, :list, required: true
  attr :total, :integer, required: true
  attr :tone_class, :map, required: true

  defp row(assigns) do
    ~H"""
    <div data-role={"composition-row-" <> Phoenix.Naming.underscore(@label)}>
      <div class="flex items-baseline justify-between text-xs uppercase tracking-wide text-base-content/60 mb-1">
        <span>{@label}</span>
      </div>
      <div :if={@buckets != []} class="flex h-3 rounded overflow-hidden bg-base-300">
        <div
          :for={{key, bucket} <- @buckets}
          class={[Map.get(@tone_class, key, "bg-base-content/40")]}
          style={"width: #{percent(bucket.total_copies, @total)}%"}
          title={"#{label_for(key)} · #{bucket.owned_unique} unique · #{bucket.total_copies} copies"}
        />
      </div>
      <div class="flex flex-wrap gap-x-3 gap-y-1 mt-1 text-xs text-base-content/70">
        <span :for={{key, bucket} <- @buckets} class="tabular-nums">
          {label_for(key)}: {bucket.owned_unique} ({bucket.total_copies})
        </span>
      </div>
    </div>
    """
  end

  defp percent(_, 0), do: 0

  defp percent(value, total) do
    Float.round(value / total * 100, 2)
  end

  defp label_for(key) when is_binary(key), do: String.capitalize(key)
  defp label_for(key) when is_atom(key), do: key |> Atom.to_string() |> String.capitalize()
end
