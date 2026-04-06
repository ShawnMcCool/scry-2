defmodule Scry2.Console.Entry do
  @moduledoc """
  A single captured log entry in the console buffer.

  Each entry has a stable monotonic integer `id` for DOM identity and
  ordering, a UTC timestamp, a level, a component atom, the already-rendered
  message text, an optional module atom (from logger metadata), and a pruned
  scalar metadata map.

  `component` is always set — never nil. `Scry2.Console.CaptureLogOutput` assigns a
  component via classification rules (explicit `:component` metadata wins;
  otherwise the emitting module is classified). `module` may be nil when
  MFA metadata is not available.
  """

  @enforce_keys [:id, :timestamp, :level, :component, :message]
  defstruct [
    :id,
    :timestamp,
    :level,
    :component,
    :module,
    :message,
    metadata: %{}
  ]

  @type level :: :debug | :info | :warning | :error

  @type t :: %__MODULE__{
          id: non_neg_integer(),
          timestamp: DateTime.t(),
          level: level(),
          component: atom(),
          module: atom() | nil,
          message: binary(),
          metadata: map()
        }

  @doc """
  Constructs a new `%Entry{}` from a keyword list or map.

  Required keys: `:id`, `:timestamp`, `:level`, `:component`, `:message`.
  Optional keys: `:module` (defaults to `nil`), `:metadata` (defaults to `%{}`).

  Raises `KeyError` if any required key is missing.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      id: Map.fetch!(attrs, :id),
      timestamp: Map.fetch!(attrs, :timestamp),
      level: Map.fetch!(attrs, :level),
      component: Map.fetch!(attrs, :component),
      message: Map.fetch!(attrs, :message),
      module: Map.get(attrs, :module, nil),
      metadata: Map.get(attrs, :metadata, %{})
    }
  end
end
