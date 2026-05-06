defmodule Scry2Web.CardComponents do
  @moduledoc """
  Reusable function components for displaying card images.

  These components render `<img>` tags pointing to the card image
  Plug route (`/images/cards/{arena_id}.jpg`). Call
  `Scry2.Cards.ImageCache.ensure_cached/2` in your LiveView mount
  before rendering — this ensures images are on disk before the
  browser requests them.

  ## Usage

      # In mount:
      ImageCache.ensure_cached(arena_ids)

      # In template:
      <.card_image arena_id={91001} name="Lightning Bolt" />
      <.card_hand arena_ids={[91001, 91002, 91003]} />
  """

  use Phoenix.Component

  alias Scry2.Cards.ImageCache

  @doc """
  Renders a single card image. If the image is not cached, shows a placeholder.

  Pass `id` to override the default `"card-img-{arena_id}"` when the same
  arena_id appears multiple times on the page (e.g. stacked copies in a grid).

  ## Examples

      <.card_image arena_id={91001} />
      <.card_image arena_id={91001} name="Lightning Bolt" class="w-24" />
      <.card_image arena_id={91001} id="card-grid-91001-2" class="w-16" />
  """
  attr :arena_id, :integer, required: true
  attr :name, :string, default: "Card image"
  attr :class, :string, default: "w-[4.5rem]"
  attr :id, :string, default: nil
  attr :cached, :boolean, default: nil
  attr :rest, :global

  def card_image(assigns) do
    assigns =
      assigns
      |> assign(:src, ImageCache.url_for(assigns.arena_id))
      |> assign(
        :cached?,
        (assigns.cached != nil && assigns.cached) || ImageCache.cached?(assigns.arena_id)
      )

    ~H"""
    <img
      :if={@cached?}
      id={@id || "card-img-#{@arena_id}"}
      src={@src}
      alt={@name}
      loading="lazy"
      class={["rounded-sm aspect-[488/680]", @class]}
      phx-hook="CardHover"
      {@rest}
    />
    <div
      :if={!@cached?}
      class={[
        "rounded-sm bg-base-300 flex items-center justify-center text-base-content/20 aspect-[488/680]",
        @class
      ]}
      {@rest}
    >
      <Scry2Web.CoreComponents.icon name="hero-photo" class="size-4" />
    </div>
    """
  end

  @doc """
  Renders a card name as a hoverable span that shows the card image popup on hover.
  Falls back to a plain span if the image is not cached.

  Pass `id` to override the default `"card-name-{arena_id}"` when the same
  arena_id appears multiple times on the page.

  ## Examples

      <.card_name arena_id={91001} name="Lightning Bolt" />
      <.card_name arena_id={91001} name="Lightning Bolt" class="text-sm" />
  """
  attr :arena_id, :integer, required: true
  attr :name, :string, required: true
  attr :id, :string, default: nil
  attr :class, :string, default: nil
  attr :cached, :boolean, default: nil

  def card_name(assigns) do
    assigns =
      assigns
      |> assign(:src, ImageCache.url_for(assigns.arena_id))
      |> assign(
        :cached?,
        (assigns.cached != nil && assigns.cached) || ImageCache.cached?(assigns.arena_id)
      )

    ~H"""
    <span
      :if={@cached?}
      id={@id || "card-name-#{@arena_id}"}
      phx-hook="CardHover"
      data-card-src={@src}
      data-card-alt={@name}
      class={["cursor-default", @class]}
    >
      {@name}
    </span>
    <span :if={!@cached?} class={@class}>{@name}</span>
    """
  end

  @doc """
  Renders a horizontal row of card images.

  Used for mulligan hands, opening hands, deck displays — any
  context where multiple cards are shown inline.

  ## Examples

      <.card_hand arena_ids={[91001, 91002, 91003]} />
      <.card_hand arena_ids={hand} card_names={%{91001 => "Bolt"}} class="w-16" />
  """

  attr :arena_ids, :list, required: true
  attr :card_names, :map, default: %{}
  attr :class, :string, default: "w-[4.5rem]"

  def card_hand(assigns) do
    ~H"""
    <div class="flex gap-1 items-start">
      <.card_image
        :for={arena_id <- @arena_ids}
        arena_id={arena_id}
        name={Map.get(@card_names, arena_id, "Card image")}
        class={@class}
      />
    </div>
    """
  end

  @doc """
  Renders a card image with a colored border and count badge for deck diffs.

  `kind` is `:added` (green border, + badge) or `:removed` (red border, − badge).

  ## Examples

      <.card_diff_image arena_id={91001} name="Bolt" count={2} kind={:added} />
      <.card_diff_image arena_id={91001} name="Bolt" count={1} kind={:removed} />
  """
  attr :arena_id, :integer, required: true
  attr :name, :string, default: "Card image"
  attr :count, :integer, required: true
  attr :kind, :atom, values: [:added, :removed], required: true
  attr :class, :string, default: "w-20"
  attr :id, :string, default: nil

  def card_diff_image(assigns) do
    assigns =
      assign(assigns,
        border_class:
          if(assigns.kind == :added,
            do: "ring-2 ring-success",
            else: "ring-2 ring-error opacity-70"
          ),
        badge_class:
          if(assigns.kind == :added,
            do: "bg-success text-success-content",
            else: "bg-error text-error-content"
          ),
        badge_text: if(assigns.kind == :added, do: "+#{assigns.count}", else: "−#{assigns.count}")
      )

    ~H"""
    <div class="relative">
      <div class={[@border_class, "rounded-md"]}>
        <.card_image
          arena_id={@arena_id}
          name={@name}
          class={@class}
          id={@id || "diff-#{@kind}-#{@arena_id}"}
        />
      </div>
      <span class={[
        "absolute top-1 right-1 rounded px-1 text-xs font-bold pointer-events-none",
        @badge_class
      ]}>
        {@badge_text}
      </span>
    </div>
    """
  end
end
