defmodule Scry2.Health.Checks.ConfigTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Scry2.Health.Check
  alias Scry2.Health.Checks.Config

  describe "database_writable/1" do
    test "error when path is nil" do
      check = Config.database_writable(nil)
      assert %Check{status: :error} = check
    end

    test "ok when the file and its dir are writable", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "scry_2.db")
      File.write!(path, "")

      check = Config.database_writable(path)
      assert %Check{status: :ok} = check
      assert check.summary == path
    end

    test "error when the file does not exist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nonexistent.db")

      check = Config.database_writable(path)
      assert %Check{status: :error} = check
    end
  end

  describe "data_dirs_exist/1" do
    test "ok when all dirs exist and are writable", %{tmp_dir: tmp_dir} do
      a = Path.join(tmp_dir, "a")
      b = Path.join(tmp_dir, "b")
      File.mkdir_p!(a)
      File.mkdir_p!(b)

      check = Config.data_dirs_exist(cache_dir: a, image_cache_dir: b)
      assert %Check{status: :ok} = check
    end

    test "error when a dir is missing", %{tmp_dir: tmp_dir} do
      existing = Path.join(tmp_dir, "exists")
      File.mkdir_p!(existing)
      missing = Path.join(tmp_dir, "missing")

      check =
        Config.data_dirs_exist(cache_dir: existing, image_cache_dir: missing)

      assert %Check{status: :error} = check
      assert check.detail =~ "image_cache_dir"
      assert check.detail =~ "missing"
    end

    test "error when a dir is nil" do
      check = Config.data_dirs_exist(cache_dir: nil)
      assert %Check{status: :error} = check
      assert check.detail =~ "unset"
    end
  end
end
