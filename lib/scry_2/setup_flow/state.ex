defmodule Scry2.SetupFlow.State do
  @moduledoc """
  Typed state for the first-run setup tour.

  The tour is a narrated walkthrough with five steps; its state tracks
  the current step, any information the user has entered (such as a
  manual `Player.log` path), and which steps have been visited so the
  UI can render a progress indicator.

  State transitions are handled by the pure functions `advance/1` and
  `previous/1` — the LiveView is a thin wrapper over these.
  """

  @enforce_keys [:step]
  defstruct step: :welcome,
            detected_path: nil,
            manual_path: nil,
            manual_path_error: nil,
            completed_steps: MapSet.new()

  @type step ::
          :welcome
          | :locate_log
          | :card_status
          | :verify_events
          | :memory_reading
          | :done

  @type t :: %__MODULE__{
          step: step(),
          detected_path: String.t() | nil,
          manual_path: String.t() | nil,
          manual_path_error: String.t() | nil,
          completed_steps: MapSet.t(step())
        }

  # Step order — single source of truth for traversal.
  @steps [:welcome, :locate_log, :card_status, :verify_events, :memory_reading, :done]

  @doc "Returns the canonical list of steps in order."
  @spec steps() :: [step()]
  def steps, do: @steps

  @doc """
  Advances to the next step, marking the current step as completed.

  At the final step (`:done`), further calls are no-ops.
  """
  @spec advance(t()) :: t()
  def advance(%__MODULE__{step: :done} = state), do: state

  def advance(%__MODULE__{step: current} = state) do
    next = next_step(current)
    %{state | step: next, completed_steps: MapSet.put(state.completed_steps, current)}
  end

  @doc """
  Moves back to the previous step. At `:welcome` further calls are
  no-ops. Does not un-mark completed steps.
  """
  @spec previous(t()) :: t()
  def previous(%__MODULE__{step: :welcome} = state), do: state

  def previous(%__MODULE__{step: current} = state) do
    %{state | step: previous_step(current)}
  end

  @doc """
  Returns the 1-based index of the given step within the canonical list.
  Useful for rendering "Step X of Y" indicators.
  """
  @spec step_number(step()) :: pos_integer()
  def step_number(step) when step in @steps do
    Enum.find_index(@steps, &(&1 == step)) + 1
  end

  @doc "Total number of steps in the tour."
  @spec total_steps() :: pos_integer()
  def total_steps, do: length(@steps)

  defp next_step(current) do
    case Enum.find_index(@steps, &(&1 == current)) do
      nil -> current
      idx -> Enum.at(@steps, idx + 1, current)
    end
  end

  defp previous_step(current) do
    case Enum.find_index(@steps, &(&1 == current)) do
      nil -> current
      0 -> current
      idx -> Enum.at(@steps, idx - 1)
    end
  end
end
