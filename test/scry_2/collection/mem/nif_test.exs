defmodule Scry2.Collection.Mem.NifTest do
  use ExUnit.Case, async: true

  alias Scry2.Collection.Mem.Nif

  test "ping/0 returns :pong, confirming the NIF loaded" do
    assert Nif.ping() == :pong
  end

  describe "Linux primitives against the current BEAM process" do
    @describetag :external

    setup do
      self_pid = :os.getpid() |> to_string() |> String.to_integer()
      %{self_pid: self_pid}
    end

    test "list_maps/1 returns at least one mapped region for self",
         %{self_pid: self_pid} do
      assert {:ok, maps} = Nif.list_maps(self_pid)
      assert is_list(maps)
      assert length(maps) > 0

      sample = List.first(maps)

      assert %{
               start: start,
               end_addr: end_addr,
               perms: perms,
               path: _path
             } = sample

      assert is_integer(start) and start >= 0
      assert is_integer(end_addr) and end_addr > start
      assert is_binary(perms) and byte_size(perms) == 4
    end

    test "read_bytes/3 reads the first page of a known r-xp mapping",
         %{self_pid: self_pid} do
      {:ok, maps} = Nif.list_maps(self_pid)

      # Pick the first executable mapping (r-xp) — it's guaranteed to
      # be readable and in a normal virtual-memory region.
      {:ok, exec_map} =
        maps
        |> Enum.find(fn m -> String.starts_with?(m.perms, "r-x") end)
        |> case do
          nil -> :error
          m -> {:ok, m}
        end

      assert {:ok, bytes} = Nif.read_bytes(self_pid, exec_map.start, 16)
      assert byte_size(bytes) == 16
    end

    test "find_process/1 finds the current BEAM process",
         %{self_pid: self_pid} do
      assert {:ok, ^self_pid} =
               Nif.find_process(fn %{pid: pid} -> pid == self_pid end)
    end

    test "find_process/1 returns :not_found for an impossible predicate" do
      assert Nif.find_process(fn _ -> false end) == {:error, :not_found}
    end
  end
end
