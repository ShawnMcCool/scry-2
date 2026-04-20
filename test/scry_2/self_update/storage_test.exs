defmodule Scry2.SelfUpdate.StorageTest do
  use Scry2.DataCase, async: false
  alias Scry2.SelfUpdate.Storage
  alias Scry2.SelfUpdate.UpdateChecker

  setup do
    UpdateChecker.clear_cache()
    Storage.clear_all!()
    on_exit(fn -> UpdateChecker.clear_cache() end)
    :ok
  end

  test "record_check_result/1 writes last_check_at and latest_known" do
    release = %{
      tag: "v0.15.0",
      version: "0.15.0",
      published_at: "2026-04-20T12:00:00Z",
      html_url: "http://example",
      body: "notes"
    }

    :ok = Storage.record_check_result({:ok, release})

    assert Storage.last_check_at() != nil
    assert {:ok, stored} = Storage.latest_known()
    assert stored.tag == "v0.15.0"
    assert stored.version == "0.15.0"
  end

  test "record_check_result/1 records error results without clobbering latest_known" do
    release = %{
      tag: "v0.15.0",
      version: "0.15.0",
      published_at: nil,
      html_url: "",
      body: ""
    }

    :ok = Storage.record_check_result({:ok, release})
    :ok = Storage.record_check_result({:error, {:rate_limited, 1_234_567}})

    assert {:ok, %{tag: "v0.15.0"}} = Storage.latest_known()
  end

  test "record_check_result/1 updates last_check_at on error" do
    :ok = Storage.record_check_result({:error, :transport})
    assert Storage.last_check_at() != nil
  end

  test "latest_known/0 returns :none when no record" do
    assert Storage.latest_known() == :none
  end

  test "hydrate!/0 populates the UpdateChecker cache" do
    release = %{
      tag: "v0.15.0",
      version: "0.15.0",
      published_at: nil,
      html_url: "",
      body: ""
    }

    :ok = Storage.record_check_result({:ok, release})
    UpdateChecker.clear_cache()
    :ok = Storage.hydrate!()

    assert {:ok, %{tag: "v0.15.0"}} = UpdateChecker.cached_latest_release()
  end

  test "hydrate!/0 is a no-op when no record" do
    UpdateChecker.clear_cache()
    :ok = Storage.hydrate!()
    assert UpdateChecker.cached_latest_release() == :none
  end
end
