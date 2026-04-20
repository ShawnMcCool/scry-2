defmodule Scry2.VersionTest do
  use ExUnit.Case, async: true
  alias Scry2.Version

  test "current/0 returns the mix.exs version as a string" do
    version = Version.current()
    assert is_binary(version)
    assert Regex.match?(~r/^\d+\.\d+\.\d+/, version)
  end

  test "current/0 matches Application.spec/2" do
    assert Version.current() == to_string(Application.spec(:scry_2, :vsn))
  end
end
