defmodule Scry2.Service.Backend.UnmanagedTest do
  use ExUnit.Case, async: true

  alias Scry2.Service.Backend.Unmanaged

  test "name/1 is 'unmanaged'" do
    assert Unmanaged.name([]) == "unmanaged"
  end

  test "capabilities are status-only" do
    assert Unmanaged.capabilities() == %{
             can_restart: false,
             can_stop: false,
             can_status: true
           }
  end

  test "state/1 reports active" do
    assert %{backend: :unmanaged, active: true} = Unmanaged.state([])
  end

  test "restart/1 returns :not_supported" do
    assert Unmanaged.restart([]) == :not_supported
  end

  test "stop/1 returns :not_supported" do
    assert Unmanaged.stop([]) == :not_supported
  end
end
