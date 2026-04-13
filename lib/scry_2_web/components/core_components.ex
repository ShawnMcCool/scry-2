defmodule Scry2Web.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://hexdocs.pm/phoenix_live_view/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash kind={:info} phx-mounted={show("#flash")}>Welcome Back!</.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert alert-soft w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label="close">
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://hexdocs.pm/phoenix_html/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">Actions</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  @doc """
  Renders a stat card with a muted title and large value ([UIDR-003]).

  ## Examples

      <.stat_card title="Matches" value={42} />
      <.stat_card title="Errors" value={3} class="text-error" />
  """
  attr :title, :string, required: true
  attr :value, :any, required: true
  attr :class, :string, default: ""
  slot :icon

  def stat_card(assigns) do
    ~H"""
    <div class="card bg-base-200">
      <div class="card-body p-4 items-center text-center">
        <p class="text-xs uppercase text-base-content/60 flex items-center gap-1">
          {render_slot(@icon)}
          {@title}
        </p>
        <p class={["text-2xl font-semibold font-beleren", @class]}>{@value}</p>
      </div>
    </div>
    """
  end

  @doc """
  Renders an MTGA wildcard lotus icon in the appropriate rarity color.

  ## Examples

      <.wildcard_icon rarity="common" />
      <.wildcard_icon rarity="mythic" class="size-6" />
  """
  attr :rarity, :string, values: ~w(common uncommon rare mythic), required: true
  attr :class, :string, default: "size-4 inline-block"

  @wildcard_colors %{
    "common" => "#9ca3af",
    "uncommon" => "#3b82f6",
    "rare" => "#f59e0b",
    "mythic" => "#dc2626"
  }

  def wildcard_icon(assigns) do
    assigns = assign(assigns, :color, @wildcard_colors[assigns.rarity])

    ~H"""
    <svg viewBox="0 0 24 24" fill={@color} class={@class} aria-label={"#{@rarity} wildcard"}>
      <path d="M12 2C12 2 9 6 9 9C9 11 10.5 12.5 12 13C13.5 12.5 15 11 15 9C15 6 12 2 12 2Z" />
      <path d="M7 8C7 8 3 10 3 13C3 15.5 5.5 16.5 7.5 16C6 14.5 6 12 7 8Z" opacity="0.85" />
      <path d="M17 8C17 8 21 10 21 13C21 15.5 18.5 16.5 16.5 16C18 14.5 18 12 17 8Z" opacity="0.85" />
      <path d="M5 14C5 14 2 17 3.5 20C4.5 22 7 21.5 8.5 20C6.5 19.5 5.5 17 5 14Z" opacity="0.7" />
      <path
        d="M19 14C19 14 22 17 20.5 20C19.5 22 17 21.5 15.5 20C17.5 19.5 18.5 17 19 14Z"
        opacity="0.7"
      />
      <path
        d="M12 13C12 13 10 17 10 20C10 22 12 23 12 23C12 23 14 22 14 20C14 17 12 13 12 13Z"
        opacity="0.9"
      />
    </svg>
    """
  end

  @doc """
  Renders a centered empty-state message with an icon.

  ## Examples

      <.empty_state>No matches recorded yet.</.empty_state>
      <.empty_state icon="hero-beaker">No cards imported.</.empty_state>
  """
  attr :icon, :string, default: "hero-inbox"
  slot :inner_block, required: true

  def empty_state(assigns) do
    ~H"""
    <div class="flex flex-col items-center justify-center py-12 text-base-content/50">
      <.icon name={@icon} class="size-8 mb-3" />
      <p class="text-sm">{render_slot(@inner_block)}</p>
    </div>
    """
  end

  @doc """
  Renders a back-navigation link with a left arrow.

  ## Examples

      <.back_link navigate={~p"/matches"} label="All matches" />
  """
  attr :navigate, :string, required: true
  attr :label, :string, required: true

  def back_link(assigns) do
    ~H"""
    <.link navigate={@navigate} class="link text-sm">&larr; {@label}</.link>
    """
  end

  @doc """
  Renders a win/loss result badge ([UIDR-008]).

  ## Examples

      <.result_badge won={true} />
      <.result_badge won={nil} />
  """
  attr :won, :boolean, default: nil

  def result_badge(assigns) do
    {class, label} =
      case assigns.won do
        true -> {"badge-soft badge-success", "Won"}
        false -> {"badge-soft badge-error", "Lost"}
        nil -> {"badge-ghost", "—"}
      end

    assigns = Phoenix.Component.assign(assigns, badge_class: class, badge_label: label)

    ~H"""
    <span class={["badge badge-sm", @badge_class]}>{@badge_label}</span>
    """
  end

  @doc """
  Renders a card rarity badge ([UIDR-008]).

  ## Examples

      <.rarity_badge rarity="mythic" />
      <.rarity_badge rarity="common" />
  """
  attr :rarity, :string, required: true

  def rarity_badge(assigns) do
    class =
      case assigns.rarity do
        "mythic" -> "badge-soft badge-warning"
        "rare" -> "badge-soft badge-accent"
        "uncommon" -> "badge-soft badge-info"
        _other -> "badge-ghost"
      end

    assigns = Phoenix.Component.assign(assigns, badge_class: class)

    ~H"""
    <span class={["badge badge-sm", @badge_class]}>{@rarity}</span>
    """
  end

  @doc """
  Renders any symbol from the Mana icon font by its exact suffix code.

  Use the full catalog at https://mana.andrewgioia.com/icons.html to find the
  right suffix. The `ms-{symbol}` class is applied directly — no enumeration,
  no mapping. See UIDR-006 for the usage policy and full symbol taxonomy.

  ## Attributes

  - `:symbol` — required. The suffix code, e.g. `"u"`, `"tap"`, `"ability-flying"`,
    `"guild-izzet"`, `"counter-plus"`, `"artifact"`.
  - `:cost` — boolean, default `false`. Adds `ms-cost` for the round pip style.
    Use for mana color pips; omit for ability symbols, card types, tap, etc.
  - `:size` — optional. `"2x"` | `"3x"` | `"4x"` | `"5x"` | `"6x"`.
  - `:class` — optional extra CSS classes.
  - `:label` — optional aria-label override. Defaults to the symbol code.

  ## Examples

      <.mana_symbol symbol="u" cost />
      <.mana_symbol symbol="tap" />
      <.mana_symbol symbol="ability-flying" size="2x" />
      <.mana_symbol symbol="guild-izzet" />
      <.mana_symbol symbol="artifact" />
      <.mana_symbol symbol="counter-plus" />
  """
  attr :symbol, :string, required: true
  attr :cost, :boolean, default: false
  attr :size, :string, default: nil
  attr :class, :string, default: nil
  attr :label, :string, default: nil

  def mana_symbol(assigns) do
    ~H"""
    <i
      class={["ms", "ms-#{@symbol}", @cost && "ms-cost", @size && "ms-#{@size}", @class]}
      role="img"
      aria-label={@label || @symbol}
    />
    """
  end

  @doc """
  Renders a single MTG mana color pip using the Mana icon font.

  Colorless ("C") renders the `ms-c` glyph. Empty string or nil renders nothing.

  ## Examples

      <.mana_pip color="U" />
      <.mana_pip color="W" size="2x" />
  """
  attr :color, :string, required: true
  attr :size, :string, default: nil

  def mana_pip(%{color: color} = assigns) when color in [nil, ""], do: ~H""

  def mana_pip(assigns) do
    assigns =
      assigns
      |> assign(:symbol, String.downcase(assigns.color))
      |> assign(:label, mana_color_label(assigns.color))

    ~H"""
    <.mana_symbol symbol={@symbol} cost size={@size} label={@label} />
    """
  end

  @doc """
  Renders MTG mana color pips from a color string like "GRW".

  An empty or nil string means colorless — renders a single `ms-c` pip.

  ## Examples

      <.mana_pips colors="GRW" />
      <.mana_pips colors="" />
      <.mana_pips colors="UB" size="2x" />
      <.mana_pips colors="WB" class="text-xs" />
  """
  attr :colors, :string, required: true
  attr :size, :string, default: nil
  attr :class, :string, default: nil

  def mana_pips(assigns) do
    pips =
      case assigns.colors do
        nil -> ["C"]
        "" -> ["C"]
        colors -> String.graphemes(colors)
      end

    assigns = assign(assigns, :pips, pips)

    ~H"""
    <span class={["inline-flex gap-0.5 items-center", @class]}>
      <.mana_pip :for={color <- @pips} color={color} size={@size} />
    </span>
    """
  end

  @doc false
  def mana_color_class("W"), do: "text-amber-100"
  def mana_color_class("U"), do: "text-sky-400"
  def mana_color_class("B"), do: "text-violet-400"
  def mana_color_class("R"), do: "text-red-400"
  def mana_color_class("G"), do: "text-emerald-400"
  def mana_color_class(_), do: "text-base-content/40"

  @doc """
  Renders an MTG set/expansion symbol using the Keyrune icon font.

  Accepts a set code (e.g. `"TMT"`, `"FDN"`, `"MKM"`) and renders the
  corresponding expansion symbol. Codes are case-insensitive.

  ## Attributes

  - `:code` — required. The 3-letter set code (e.g. `"TMT"`, `"fdn"`).
  - `:rarity` — optional. `"common"` | `"uncommon"` | `"rare"` | `"mythic"`.
    Adds Keyrune's built-in rarity gradient coloring.
  - `:size` — optional. `"2x"` | `"3x"` | `"4x"` | `"5x"` | `"6x"`.
  - `:class` — optional extra CSS classes.
  - `:label` — optional aria-label override. Defaults to the set code.

  ## Examples

      <.set_icon code="TMT" />
      <.set_icon code="FDN" rarity="rare" />
      <.set_icon code="MKM" size="2x" class="text-base-content/60" />
  """
  attr :code, :string, required: true
  attr :rarity, :string, default: nil
  attr :size, :string, default: nil
  attr :class, :string, default: nil
  attr :label, :string, default: nil

  def set_icon(assigns) do
    assigns = assign(assigns, :lower_code, String.downcase(assigns.code))

    ~H"""
    <i
      class={[
        "ss",
        "ss-#{@lower_code}",
        @rarity && "ss-#{@rarity}",
        @size && "ss-#{@size}",
        @class
      ]}
      role="img"
      aria-label={@label || @code}
    />
    """
  end

  @doc """
  Renders an inline MTGA currency icon (gold coin or gem).

  ## Attributes

  - `:type` — required. `"Gold"` or `"Gems"` (case-insensitive).
  - `:class` — optional extra CSS classes.

  ## Examples

      <.currency_icon type="Gold" />
      <.currency_icon type="Gems" class="size-4" />
  """
  attr :type, :string, required: true
  attr :class, :string, default: "size-3.5"

  def currency_icon(%{type: type} = assigns) do
    assigns =
      assign(assigns,
        src:
          if(String.downcase(type) in ["gold"], do: "/images/coin.png", else: "/images/gem.png"),
        alt: if(String.downcase(type) in ["gold"], do: "Gold", else: "Gems")
      )

    ~H"""
    <img src={@src} alt={@alt} class={["inline-block align-middle", @class]} />
    """
  end

  defp mana_color_label("W"), do: "White mana"
  defp mana_color_label("U"), do: "Blue mana"
  defp mana_color_label("B"), do: "Black mana"
  defp mana_color_label("R"), do: "Red mana"
  defp mana_color_label("G"), do: "Green mana"
  defp mana_color_label("C"), do: "Colorless mana"
  defp mana_color_label(other), do: "#{other} mana"

  @doc """
  Formats an MTGA event name into a readable label.

  ## Examples

      format_event_name("QuickDraft_FDN_20260323")
      # => "Quick Draft — FDN"
  """
  def format_event_name(event_name) when is_binary(event_name) do
    case String.split(event_name, "_") do
      [prefix, set_code | _] ->
        label =
          prefix
          |> String.replace("QuickDraft", "Quick Draft")
          |> String.replace("PremierDraft", "Premier Draft")
          |> String.replace("CompDraft", "Comp Draft")
          |> String.replace("TradDraft", "Traditional Draft")
          |> String.replace("BotDraft", "Bot Draft")

        "#{label} — #{set_code}"

      _ ->
        event_name
    end
  end

  def format_event_name(nil), do: "Unknown Event"

  @doc """
  Renders an MTGA rank icon.

  The `rank` string should be a rank name from the MTGA log (e.g.,
  "Gold", "Platinum", "Mythic"). The `format_type` determines which
  icon set to use: "Limited" or "Constructed" (defaults to "Limited").

  ## Examples

      <.rank_icon rank="Gold" />
      <.rank_icon rank="Platinum" format_type="Constructed" class="h-6" />
  """
  attr :rank, :string, required: true
  attr :format_type, :string, default: "Limited"
  attr :class, :string, default: "h-5"

  def rank_icon(assigns) do
    rank_slug = rank_to_slug(assigns.rank)
    side = if assigns.format_type == "Constructed", do: "constructed", else: "limited"
    assigns = assign(assigns, :src, "/images/ranks/#{side}-#{rank_slug}.png")

    ~H"""
    <img :if={@src} src={@src} alt={@rank} class={["inline-block", @class]} />
    """
  end

  defp rank_to_slug(nil), do: nil

  defp rank_to_slug(rank) when is_binary(rank) do
    rank
    |> String.downcase()
    |> String.replace(~r/\s+\d+$/, "")
    |> String.trim()
    |> case do
      "beginner" -> "bronze"
      slug -> slug
    end
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # You can make use of gettext to translate error messages by
    # uncommenting and adjusting the following code:

    # if count = opts[:count] do
    #   Gettext.dngettext(Scry2Web.Gettext, "errors", msg, msg, count, opts)
    # else
    #   Gettext.dgettext(Scry2Web.Gettext, "errors", msg, opts)
    # end

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
