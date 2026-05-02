defmodule Scry2.Collection.BuildChange do
  @moduledoc """
  Compare the most recently observed walker `build_hint` against the
  user's last-acknowledged value.

  The walker (`Scry2.Collection.Reader`) reads MTGA's process memory
  using offsets and pointer chains that are tied to a specific MTGA
  build. When MTGA ships a new client build, the layout can shift and
  the walker may stop returning correct data. The `build_hint` field
  on each `Scry2.Collection.Snapshot` records the build that produced
  the snapshot; comparing the most recent value to a stored
  acknowledgement gives the UI a way to surface "MTGA was updated;
  please verify the memory reader is still working."

  This module is a pure-function comparator. The acknowledged value
  is persisted by `Scry2.Collection`; auto-acknowledgement on first
  observation also happens there, on snapshot save.
  """

  @typedoc "Result of comparing acknowledged vs. current build_hint."
  @type t ::
          :no_data
          | :first_seen
          | :current
          | {:changed, prev :: String.t(), current :: String.t()}

  @doc """
  Compare `acknowledged` (the value the user has accepted as known-good)
  against `current` (the build_hint stamped on the latest snapshot).

  Outcomes:

    * `:no_data` — no walker data yet (`current == nil`).
    * `:first_seen` — walker has data, user has never acknowledged a
      build (`acknowledged == nil`); the caller should auto-acknowledge.
    * `:current` — values match; nothing to alert about.
    * `{:changed, prev, current}` — MTGA build changed; the user
      should verify the memory reader is still working.
  """
  @spec detect(String.t() | nil, String.t() | nil) :: t()
  def detect(_acknowledged, nil), do: :no_data
  def detect(nil, current) when is_binary(current), do: :first_seen
  def detect(same, same) when is_binary(same), do: :current

  def detect(acknowledged, current)
      when is_binary(acknowledged) and is_binary(current),
      do: {:changed, acknowledged, current}
end
