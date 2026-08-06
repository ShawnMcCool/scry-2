defmodule Scry2Web.Components.DeckExport do
  @moduledoc """
  Handing a deck to MTGA: the clipboard button, the fallback text view, and
  the two flashes that report whether the copy landed. Used by both the deck
  library and the netdeck catalog, so the wording and the recovery path are
  the same wherever a deck is exported.

  The button copies through the `ClipboardCopy` hook, which pushes `copied`
  or `copy_failed` back to the host LiveView. `copy_failed_flash/0` names the
  disclosure `mtga_import_text/1` renders, so every page with the button must
  render the disclosure too — otherwise the failure message points at
  something that isn't on the page.
  """
  use Phoenix.Component

  import Scry2Web.CoreComponents, only: [icon: 1]

  @import_text_label "View MTGA import text"

  attr :export_text, :string, required: true
  attr :disabled, :boolean, default: false
  attr :class, :string, default: nil

  def copy_to_mtga_button(assigns) do
    ~H"""
    <button
      type="button"
      class={["btn btn-primary btn-sm", @class]}
      phx-hook="ClipboardCopy"
      id="copy-to-mtga-button"
      data-copy-text={@export_text}
      disabled={@disabled}
      title="Copy this deck in MTGA's import format, then click Import in the Deck Builder."
    >
      <.icon name="hero-clipboard-document" class="size-4" /> Copy to MTGA
    </button>
    """
  end

  attr :export_text, :string, required: true
  attr :class, :string, default: nil

  def mtga_import_text(assigns) do
    assigns = assign(assigns, :label, @import_text_label)

    ~H"""
    <details :if={@export_text not in [nil, ""]} class={["group", @class]}>
      <summary class="cursor-pointer text-xs text-base-content/55 inline-flex items-center gap-1 list-none">
        <.icon name="hero-chevron-right" class="size-3 transition-transform group-open:rotate-90" />
        {@label}
      </summary>
      <pre class="mt-2 p-3 bg-base-200 rounded text-xs font-mono whitespace-pre-wrap break-all"><%= @export_text %></pre>
    </details>
    """
  end

  @doc "Flash for a successful copy: the next thing the player does."
  @spec copied_flash() :: String.t()
  def copied_flash, do: "Copied — in MTGA, click Import in the Deck Builder."

  @doc "Flash for a failed copy: the one way left to get the list out."
  @spec copy_failed_flash() :: String.t()
  def copy_failed_flash do
    "Couldn't reach the clipboard. Open “#{@import_text_label}” and copy it by hand."
  end
end
