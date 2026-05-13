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
  Prefer the status-specific helpers (`ok/4`, `warning/5`, `error/5`,
  `pending/4`) below — they make the intent obvious at the call site
  and document which fields each status expects.
  """
  @spec new(keyword()) :: t()
  def new(fields) do
    {known, _rest} =
      Keyword.split(fields, [:id, :category, :name, :status, :summary, :detail, :fix])

    struct!(__MODULE__, Keyword.put(known, :checked_at, DateTime.utc_now()))
  end

  @doc "Build a passing check. Optional `:detail` for context."
  @spec ok(atom(), category(), String.t(), String.t(), keyword()) :: t()
  def ok(id, category, name, summary, opts \\ []) do
    new(
      id: id,
      category: category,
      name: name,
      status: :ok,
      summary: summary,
      detail: Keyword.get(opts, :detail)
    )
  end

  @doc """
  Build a warning check. `:detail` and `:fix` are optional; provide
  them when the warning has a remediation path.
  """
  @spec warning(atom(), category(), String.t(), String.t(), keyword()) :: t()
  def warning(id, category, name, summary, opts \\ []) do
    new(
      id: id,
      category: category,
      name: name,
      status: :warning,
      summary: summary,
      detail: Keyword.get(opts, :detail),
      fix: Keyword.get(opts, :fix)
    )
  end

  @doc """
  Build an error check. Errors should usually carry a `:detail`
  explaining the failure and a `:fix` tag (or `:manual` when human
  action is required).
  """
  @spec error(atom(), category(), String.t(), String.t(), keyword()) :: t()
  def error(id, category, name, summary, opts \\ []) do
    new(
      id: id,
      category: category,
      name: name,
      status: :error,
      summary: summary,
      detail: Keyword.get(opts, :detail),
      fix: Keyword.get(opts, :fix)
    )
  end

  @doc "Build a pending check for transient states (still starting, waiting for first event)."
  @spec pending(atom(), category(), String.t(), String.t(), keyword()) :: t()
  def pending(id, category, name, summary, opts \\ []) do
    new(
      id: id,
      category: category,
      name: name,
      status: :pending,
      summary: summary,
      detail: Keyword.get(opts, :detail)
    )
  end
end
