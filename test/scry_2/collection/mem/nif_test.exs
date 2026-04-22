defmodule Scry2.Collection.Mem.NifTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Mem.Nif

  test "ping/0 returns :pong, confirming the NIF loaded" do
    assert Nif.ping() == :pong
  end
end
