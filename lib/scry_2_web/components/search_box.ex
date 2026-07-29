defmodule Scry2Web.Components.SearchBox do
  @moduledoc """
  A debounced text input with a suggestion dropdown — the one search-box
  mechanism behind the netdeck catalog's archetype and card bars.

  The caller owns all state: it supplies `value` and `suggestions`
  (`%{key, label, count}`) and receives events — `input_event` on debounced
  keyup, whose payload carries both `"value"` (current text) and `"key"`
  (the key that triggered it); callers MUST treat a payload of
  `%{"key" => "Escape"}` as a dismiss. `pick_event` fires with
  `phx-value-key`/`phx-value-label` when a suggestion is clicked.
  `dismiss_event` fires on click-away while suggestions are open. There is
  deliberately no `phx-keydown` Escape binding on the input: LiveView
  applies `phx-key` to every key binding on an element, so pairing it with
  `phx-keyup` would filter out every non-Escape keystroke and silently
  break typing. Suggestions render only while non-empty, absolutely
  positioned (no layout shift, no keyframe animation). Clicking a
  suggestion to fill the input relies on the click moving focus off the
  input — LiveView skips patching the value of a focused input, so the
  new `value` assign only lands once focus has left it (a Safari focus
  timing quirk is an accepted caveat here).
  """
  use Phoenix.Component

  import Scry2Web.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  attr :id, :string, required: true
  attr :value, :string, required: true
  attr :placeholder, :string, required: true
  attr :suggestions, :list, required: true
  attr :input_event, :string, required: true
  attr :pick_event, :string, required: true
  attr :dismiss_event, :string, required: true

  def search_box(assigns) do
    ~H"""
    <div
      class="relative w-full max-w-md"
      phx-click-away={@suggestions != [] && JS.push(@dismiss_event)}
    >
      <label class="input input-bordered input-sm flex w-full items-center gap-2">
        <.icon name="hero-magnifying-glass" class="size-4 text-base-content/40" />
        <input
          id={@id}
          type="text"
          phx-keyup={@input_event}
          phx-debounce="200"
          value={@value}
          placeholder={@placeholder}
          autocomplete="off"
          class="grow"
        />
      </label>
      <ul
        :if={@suggestions != []}
        id={@id <> "-suggestions"}
        class="menu absolute z-20 mt-1 w-full rounded-box border border-base-300/40 bg-base-200 shadow-lg"
      >
        <li :for={suggestion <- @suggestions}>
          <button
            type="button"
            phx-click={@pick_event}
            phx-value-key={suggestion.key}
            phx-value-label={suggestion.label}
            class="flex items-center justify-between gap-3"
          >
            <span class="truncate">{suggestion.label}</span>
            <span class="text-xs tabular-nums text-base-content/40">{suggestion.count}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end
end
