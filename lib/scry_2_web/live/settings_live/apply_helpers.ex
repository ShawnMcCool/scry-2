defmodule Scry2Web.SettingsLive.ApplyHelpers do
  @moduledoc """
  Pure helpers backing the apply-update progress modal.

  Extracted per ADR-013 so `HealthLive` stays thin wiring — the LiveView
  only owns the apply_phase/apply_error/apply_failed_at assigns and
  shuffles PubSub messages into them; everything the modal needs to
  render (labels, state per row, error formatting) lives here.
  """

  @type apply_phase ::
          nil
          | :preparing
          | :downloading
          | :extracting
          | :handing_off
          | :done
          | :failed

  # Ordered list of rows shown in the modal. `:preparing` flashes past
  # before render and has no meaningful work to display; terminal
  # states (:done, :failed) are surfaced separately from the row list.
  @visible_phases [:downloading, :extracting, :handing_off]

  @spec visible_phases() :: [atom()]
  def visible_phases, do: @visible_phases

  @doc """
  True when the modal should be rendered — an apply is in flight or has
  just completed/failed. `nil` means "idle, never started".
  """
  @spec apply_visible?(apply_phase()) :: boolean()
  def apply_visible?(nil), do: false
  def apply_visible?(_), do: true

  @spec apply_phase_label(apply_phase()) :: String.t()
  def apply_phase_label(:preparing), do: "Preparing…"
  def apply_phase_label(:downloading), do: "Downloading release"
  def apply_phase_label(:extracting), do: "Extracting files"
  def apply_phase_label(:handing_off), do: "Installing and restarting"
  def apply_phase_label(:done), do: "Update staged. Restarting…"
  def apply_phase_label(:failed), do: "Update failed"
  def apply_phase_label(nil), do: ""

  @doc """
  Classifies one phase-row against the current overall phase so the
  modal can pick an icon and text colour per row.
  """
  @spec phase_state(apply_phase(), apply_phase(), apply_phase()) ::
          :pending | :active | :done | :failed
  def phase_state(_target, nil, _failed_at), do: :pending

  def phase_state(target, :failed, failed_at) do
    cond do
      target == failed_at -> :failed
      phase_index(target) < phase_index(failed_at) -> :done
      true -> :pending
    end
  end

  def phase_state(_target, :done, _failed_at), do: :done

  def phase_state(target, current, _failed_at) do
    target_idx = phase_index(target)
    current_idx = phase_index(current)

    cond do
      target_idx < current_idx -> :done
      target_idx == current_idx -> :active
      true -> :pending
    end
  end

  defp phase_index(:preparing), do: 0
  defp phase_index(:downloading), do: 1
  defp phase_index(:extracting), do: 2
  defp phase_index(:handing_off), do: 3
  defp phase_index(:done), do: 4
  defp phase_index(_), do: 0

  @doc """
  True while the user can still cancel the apply. After the handoff
  phase the detached installer has already been spawned — there is
  nothing left to kill, so Cancel is hidden.
  """
  @spec apply_cancelable?(apply_phase()) :: boolean()
  def apply_cancelable?(phase) when phase in [:preparing, :downloading, :extracting], do: true
  def apply_cancelable?(_), do: false

  @spec phase_text_class(atom()) :: String.t()
  def phase_text_class(:pending), do: "text-sm text-base-content/40"
  def phase_text_class(:active), do: "text-sm text-base-content font-medium"
  def phase_text_class(:done), do: "text-sm text-base-content/70"
  def phase_text_class(:failed), do: "text-sm text-error"

  @doc "Formats an apply error reason into a human-readable sentence."
  @spec apply_error_label(any()) :: String.t()
  def apply_error_label(:checksum_mismatch),
    do: "Downloaded archive failed checksum verification."

  def apply_error_label(:path_traversal),
    do: "Archive contained an unsafe path. Refusing to extract."

  def apply_error_label(:spawn_failed),
    do: "Could not launch the installer."

  def apply_error_label({:download, reason}),
    do: "Download failed: #{format_reason(reason)}"

  def apply_error_label({:stage, reason}),
    do: "Archive rejected: #{format_reason(reason)}"

  def apply_error_label({:handoff, _}),
    do: "Could not hand off to the installer."

  def apply_error_label(other),
    do: "Update failed: #{format_reason(other)}"

  defp format_reason(reason) when is_atom(reason), do: to_string(reason)
  defp format_reason({tag, _detail}) when is_atom(tag), do: to_string(tag)
  defp format_reason(reason), do: inspect(reason)
end
