defmodule Scry2.NetDecking.Buildability.Result do
  @moduledoc """
  Top-level buildability result. `status` and `sort_key` are derived from
  the maindeck; `sideboard` cost is broken out separately (Bo3 needs it).
  The struct is the stable contract the UI depends on.
  """
  alias Scry2.NetDecking.Buildability.Section

  @enforce_keys [:status, :maindeck, :sideboard, :sort_key]
  defstruct [:status, :maindeck, :sideboard, :sort_key]

  @type status :: :buildable | :craftable | :short
  @type t :: %__MODULE__{
          status: status(),
          maindeck: Section.t(),
          sideboard: Section.t(),
          sort_key: {integer(), integer(), integer(), integer(), integer()}
        }
end
