defmodule Scry2.SetupFlow do
  @moduledoc """
  First-run setup tour state + persistence.

  The setup tour is a narrated walkthrough that explains what Scry2 is
  doing and surfaces failures early. Most users click through it once
  and never see it again; this module decides when to show it and
  persists the handful of user-provided values it captures.

  ## Dismissal

  The tour is dismissed under either of two conditions:

    1. **Persisted flag.** After clicking through to the `:done` step,
       `mark_completed!/0` writes `setup_completed_at` to `Scry2.Settings`.
       Even if the system breaks later, the user won't be routed back
       into the tour — they'll see the health screen with failing checks.

    2. **Derived signals.** `Scry2.Health.setup_ready?/0` returns true
       when player log is locatable, cards are imported, and at least
       one domain event has been seen. This auto-dismisses the tour for
       returning users who never completed it but whose environment
       already satisfies setup.

  ## Player.log override

  `persist_player_log_path!/1` writes to `Scry2.Settings` under
  `"mtga_logs_player_log_path"`. `Scry2.MtgaLogIngestion.LocateLogFile.override/0`
  consults Settings first, so the new path takes effect on the next
  watcher reload without a restart.
  """

  alias Scry2.Health
  alias Scry2.MtgaLogIngestion.LocateLogFile
  alias Scry2.MtgaLogIngestion.Watcher
  alias Scry2.Settings
  alias Scry2.SetupFlow.State

  @completed_key "setup_completed_at"
  @player_log_path_key "mtga_logs_player_log_path"

  @doc """
  Returns true when the first-run tour should be shown.

  The tour is *not* required (returns `false`) when either:
    * the completion flag is persisted in Settings, or
    * derived signals indicate setup is already working
  """
  @spec required?() :: boolean()
  def required? do
    not completed_persisted?() and not Health.setup_ready?()
  end

  @doc """
  Marks the tour as completed. Idempotent.
  """
  @spec mark_completed!() :: :ok
  def mark_completed! do
    Settings.put!(@completed_key, DateTime.utc_now() |> DateTime.to_iso8601())
    :ok
  end

  @doc """
  Clears the completion flag so the tour will be shown again on the
  next navigation. Called from the health screen's "Run setup tour
  again" link.
  """
  @spec reset!() :: :ok
  def reset! do
    Settings.put!(@completed_key, nil)
    :ok
  end

  @doc """
  Returns true when the persisted completion flag is set to a non-nil
  value.
  """
  @spec completed_persisted?() :: boolean()
  def completed_persisted? do
    case Settings.get(@completed_key) do
      nil -> false
      "" -> false
      _other -> true
    end
  end

  @doc """
  Persists a manually-entered `Player.log` path and asks the watcher
  to reload. Returns `{:ok, path}` on success, `{:error, reason}` if
  the path doesn't exist or isn't a regular file.
  """
  @spec persist_player_log_path!(String.t()) :: {:ok, String.t()} | {:error, term()}
  def persist_player_log_path!(path) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      not File.regular?(expanded) ->
        {:error, :not_a_file}

      true ->
        Settings.put!(@player_log_path_key, expanded)
        Watcher.reload_path()
        {:ok, expanded}
    end
  end

  @doc """
  Builds the initial state for mounting SetupLive. Populates
  `detected_path` from `LocateLogFile.resolve/0` so the Locate step
  can show the auto-detection result immediately.
  """
  @spec initial_state() :: State.t()
  def initial_state do
    detected =
      case LocateLogFile.resolve() do
        {:ok, path} -> path
        _ -> nil
      end

    %State{
      step: :welcome,
      detected_path: detected,
      manual_path: nil,
      manual_path_error: nil,
      completed_steps: MapSet.new()
    }
  end

  @doc """
  Delegates to `State.advance/1`. Provided on the facade so LiveViews
  don't need to reach into the nested module.
  """
  @spec advance(State.t()) :: State.t()
  def advance(%State{} = state), do: State.advance(state)

  @doc "Delegates to `State.previous/1`."
  @spec previous(State.t()) :: State.t()
  def previous(%State{} = state), do: State.previous(state)
end
