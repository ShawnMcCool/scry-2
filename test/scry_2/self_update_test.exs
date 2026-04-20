defmodule Scry2.SelfUpdateTest do
  use Scry2.DataCase, async: false
  alias Scry2.SelfUpdate
  alias Scry2.SelfUpdate.Storage
  alias Scry2.SelfUpdate.UpdateChecker

  setup do
    UpdateChecker.clear_cache()
    Storage.clear_all!()
    :ok
  end

  test "current_version/0 returns a version string" do
    assert is_binary(SelfUpdate.current_version())
  end

  test "cached_release/0 returns :none when no cache" do
    assert SelfUpdate.cached_release() == :none
  end

  test "cached_release/0 returns the cached release when present" do
    release = %{tag: "v0.99.0", version: "0.99.0", published_at: nil, html_url: "", body: ""}
    UpdateChecker.put_cache(release)
    assert {:ok, %{tag: "v0.99.0"}} = SelfUpdate.cached_release()
  end

  test "apply_lock_path/0 is under Scry2.Platform.data_dir/0" do
    assert SelfUpdate.apply_lock_path() |> String.starts_with?(Scry2.Platform.data_dir())
    assert Path.basename(SelfUpdate.apply_lock_path()) == "apply.lock"
  end

  test "staging_root/0 is under Scry2.Platform.data_dir/0" do
    assert SelfUpdate.staging_root() |> String.starts_with?(Scry2.Platform.data_dir())
  end

  test "enabled?/0 is false in test env" do
    refute SelfUpdate.enabled?()
  end

  test "last_check_at/0 returns nil before any check" do
    assert SelfUpdate.last_check_at() == nil
  end
end
