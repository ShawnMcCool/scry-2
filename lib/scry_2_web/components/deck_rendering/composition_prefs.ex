defmodule Scry2Web.DeckRendering.CompositionPrefs do
  @moduledoc """
  The persisted user preference for how `standard_composition/1` lays
  out a deck — one value type covering every axis the composition
  controls expose, stored under a single Settings key by
  `Scry2Web.DeckViewScope`.

  ## Fields

  - `display_mode` — which sections render: `:text | :images | :both`.
  - `top` — which section renders first when both are visible
    (`:images | :text`).
  - `text_group_by` / `images_group_by` — each section's grouping on
    the `ViewSpec.group_by` vocabulary (`:type | :mana_value`),
    independent per section.

  Incoming values (stored maps, `set_deck_view_pref` event params) are
  whitelist-parsed per field; anything unrecognised leaves the field at
  its default. Never calls `String.to_atom/1` on untrusted input.
  """

  @type display_mode :: :text | :images | :both
  @type top :: :images | :text
  @type group_by :: :type | :mana_value

  @type t :: %__MODULE__{
          display_mode: display_mode(),
          top: top(),
          text_group_by: group_by(),
          images_group_by: group_by()
        }

  defstruct display_mode: :both,
            top: :images,
            text_group_by: :type,
            images_group_by: :mana_value

  @doc """
  Parses a stored prefs map (string keys and values) into a struct.
  Missing, unknown, or invalid fields keep their defaults; non-map
  input yields the default prefs.
  """
  @spec parse(term()) :: t()
  def parse(stored) when is_map(stored) do
    Enum.reduce(stored, %__MODULE__{}, fn
      {field, value}, prefs when is_binary(field) -> put(prefs, field, value)
      _entry, prefs -> prefs
    end)
  end

  def parse(_stored), do: %__MODULE__{}

  @doc """
  Sets one field from an incoming string field/value pair — the
  `set_deck_view_pref` event contract. Unknown fields or values return
  the prefs unchanged.
  """
  @spec put(t(), term(), term()) :: t()
  def put(%__MODULE__{} = prefs, "display_mode", value) when value in ~w(text images both),
    do: %{prefs | display_mode: String.to_existing_atom(value)}

  def put(%__MODULE__{} = prefs, "top", value) when value in ~w(images text),
    do: %{prefs | top: String.to_existing_atom(value)}

  def put(%__MODULE__{} = prefs, "text_group_by", value) when value in ~w(type mana_value),
    do: %{prefs | text_group_by: String.to_existing_atom(value)}

  def put(%__MODULE__{} = prefs, "images_group_by", value) when value in ~w(type mana_value),
    do: %{prefs | images_group_by: String.to_existing_atom(value)}

  def put(%__MODULE__{} = prefs, _field, _value), do: prefs

  @doc "The prefs as a string map for Settings persistence — `parse/1`'s inverse."
  @spec to_stored(t()) :: %{String.t() => String.t()}
  def to_stored(%__MODULE__{} = prefs) do
    %{
      "display_mode" => Atom.to_string(prefs.display_mode),
      "top" => Atom.to_string(prefs.top),
      "text_group_by" => Atom.to_string(prefs.text_group_by),
      "images_group_by" => Atom.to_string(prefs.images_group_by)
    }
  end

  @doc """
  Projects `display_mode` onto the `ViewSpec.display` vocabulary — a
  section is visible when its display is a member of this list.
  """
  @spec visible_displays(t()) :: [:text | :images]
  def visible_displays(%__MODULE__{display_mode: :text}), do: [:text]
  def visible_displays(%__MODULE__{display_mode: :images}), do: [:images]
  def visible_displays(%__MODULE__{display_mode: :both}), do: [:text, :images]

  @doc """
  The visible sections in render order — `top` first when both are
  visible, otherwise just the single visible section.
  """
  @spec section_order(t()) :: [:text | :images]
  def section_order(%__MODULE__{} = prefs) do
    order =
      case prefs.top do
        :images -> [:images, :text]
        :text -> [:text, :images]
      end

    visible = visible_displays(prefs)
    Enum.filter(order, &(&1 in visible))
  end

  @doc "The `top` value the swap control should send — the other section."
  @spec flipped_top(t()) :: top()
  def flipped_top(%__MODULE__{top: :images}), do: :text
  def flipped_top(%__MODULE__{top: :text}), do: :images
end
