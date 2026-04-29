defmodule Scry2.Health.Check do
  @moduledoc """
  Typed result of a single health check.

  A `%Check{}` crosses the boundary between `Scry2.Health.Checks.*`
  (pure functions that decide a status) and `Scry2.Health` (the facade
  that runs them and builds a `%Report{}`).

  Each check has a stable `id` atom so UI code can match on it without
  inspecting the human `name` string.

  ## Fields

    * `id` — stable atom identifier (e.g. `:player_log_locatable`)
    * `category` — one of `:ingestion | :card_data | :processing | :config`
    * `name` — human-readable label for UI rendering
    * `status` — `:ok | :warning | :error | :pending`
    * `summary` — short one-line description of the current state
    * `detail` — optional longer explanation, shown expanded
    * `fix` — optional auto-fix tag dispatched by `Diagnostics.auto_fix/1`
    * `checked_at` — when the check ran
  """

  @enforce_keys [:id, :category, :name, :status]
  defstruct [
    :id,
    :category,
    :name,
    :status,
    :summary,
    :detail,
    :fix,
    :checked_at
  ]

  @type category :: :ingestion | :card_data | :processing | :config
  @type status :: :ok | :warning | :error | :pending
  @type fix :: nil | :reload_watcher | :enqueue_synthesis | :enqueue_scryfall | :manual

  @type t :: %__MODULE__{
          id: atom(),
          category: category(),
          name: String.t(),
          status: status(),
          summary: String.t() | nil,
          detail: String.t() | nil,
          fix: fix(),
          checked_at: DateTime.t() | nil
        }

  @doc """
  Builds a `%Check{}` with `checked_at` set to the current time.

  All fields except `id`, `category`, `name`, and `status` are optional.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    {known, _rest} =
      Keyword.split(fields, [:id, :category, :name, :status, :summary, :detail, :fix])

    struct!(__MODULE__, Keyword.put(known, :checked_at, DateTime.utc_now()))
  end
end
