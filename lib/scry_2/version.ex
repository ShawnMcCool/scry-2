defmodule Scry2.Version do
  @moduledoc """
  Exposes the scry_2 version string at runtime.

  The version is read from `mix.exs` at compile time and baked into the
  compiled release, so `current/0` returns the version of the code that
  is actually running.
  """

  @spec current() :: String.t()
  def current, do: to_string(Application.spec(:scry_2, :vsn))
end
