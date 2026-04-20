defmodule Scry2.SelfUpdate.ApplyLockTest do
  use ExUnit.Case, async: true
  alias Scry2.SelfUpdate.ApplyLock

  setup do
    dir = System.tmp_dir!() |> Path.join("apply_lock_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir, path: Path.join(dir, "apply.lock")}
  end

  test "acquire/2 writes the lock with pid, version, phase, started_at", %{path: path} do
    :ok = ApplyLock.acquire(path, version: "0.15.0")
    assert File.exists?(path)
    contents = path |> File.read!() |> Jason.decode!()
    assert contents["version"] == "0.15.0"
    assert contents["phase"] == "preparing"
    assert is_integer(contents["pid"])
    assert contents["started_at"]
  end

  test "update_phase/2 rewrites only the phase", %{path: path} do
    :ok = ApplyLock.acquire(path, version: "0.15.0")
    :ok = ApplyLock.update_phase(path, "handing_off")
    contents = path |> File.read!() |> Jason.decode!()
    assert contents["phase"] == "handing_off"
    assert contents["version"] == "0.15.0"
  end

  test "release/1 removes the file", %{path: path} do
    :ok = ApplyLock.acquire(path, version: "0.15.0")
    :ok = ApplyLock.release(path)
    refute File.exists?(path)
  end

  test "release/1 is idempotent when file missing", %{path: path} do
    assert :ok = ApplyLock.release(path)
  end

  test "read/1 returns :none when file missing", %{path: path} do
    assert ApplyLock.read(path) == :none
  end

  test "read/1 returns a struct when file exists", %{path: path} do
    :ok = ApplyLock.acquire(path, version: "0.15.0")
    assert {:ok, lock} = ApplyLock.read(path)
    assert lock.version == "0.15.0"
    assert lock.phase == "preparing"
  end

  test "stale?/2 returns true when lock older than given age", %{path: path} do
    :ok = ApplyLock.acquire(path, version: "0.15.0")
    {:ok, lock} = ApplyLock.read(path)
    assert ApplyLock.stale?(lock, 0) == true
    assert ApplyLock.stale?(lock, 86_400) == false
  end

  test "clear_if_stale!/2 removes stale, leaves fresh", %{path: path} do
    :ok = ApplyLock.acquire(path, version: "0.15.0")
    assert :not_stale = ApplyLock.clear_if_stale!(path, 86_400)
    assert File.exists?(path)

    assert :cleared = ApplyLock.clear_if_stale!(path, 0)
    refute File.exists?(path)
  end

  test "read/1 parses started_at into a DateTime", %{path: path} do
    :ok = ApplyLock.acquire(path, version: "0.15.0")
    {:ok, lock} = ApplyLock.read(path)
    assert %DateTime{} = lock.started_at
  end

  test "clear_if_stale!/2 removes a corrupt lock file", %{path: path} do
    File.write!(path, "not json {{{")
    assert :cleared = ApplyLock.clear_if_stale!(path, 86_400)
    refute File.exists?(path)
  end

  test "update_phase/2 returns :lock_missing when file absent", %{path: path} do
    assert {:error, :lock_missing} = ApplyLock.update_phase(path, "handing_off")
  end
end
