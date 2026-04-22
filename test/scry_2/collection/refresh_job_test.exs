defmodule Scry2.Collection.RefreshJobTest do
  use Scry2.DataCase, async: false
  use Oban.Testing, repo: Scry2.Repo

  alias Scry2.Collection
  alias Scry2.Collection.Mem.TestBackend
  alias Scry2.Collection.RefreshJob

  setup do
    TestBackend.clear_fixture()
    Collection.disable_reader!()
    :ok
  end

  test "discards the job when the reader is disabled" do
    assert {:discard, :reader_disabled} =
             perform_job(RefreshJob, %{"trigger" => "manual"})
  end

  test "persists a snapshot when the reader succeeds" do
    Collection.enable_reader!()

    heap_base = 0x0800_0000
    heap_size = 0x4000
    cards_offset = 0x1000

    entries = for i <- 0..59, do: {90_000 + i, rem(i, 4) + 1}

    cards =
      Enum.map_join(entries, "", fn {k, v} ->
        <<Bitwise.band(k, 0x7FFFFFFF)::little-signed-32, -1::little-signed-32,
          k::little-signed-32, v::little-signed-32>>
      end)

    heap_bin =
      :binary.copy(<<0>>, cards_offset) <>
        cards <>
        :binary.copy(<<0>>, heap_size - cards_offset - byte_size(cards))

    mtga_exe_base = 0x4000_0000

    TestBackend.set_fixture(
      processes: [%{pid: 4242, name: "MTGA.exe", cmdline: ""}],
      maps: [
        %{start: heap_base, end_addr: heap_base + heap_size, perms: "rw-p", path: nil},
        %{
          start: mtga_exe_base,
          end_addr: mtga_exe_base + 0x10_000,
          perms: "r--p",
          path: "C:/MTGA.exe"
        },
        %{start: 0x5000, end_addr: 0x6000, perms: "r-xp", path: "mono-2.0-bdwgc.dll"},
        %{start: 0x7000, end_addr: 0x8000, perms: "r-xp", path: "UnityPlayer.dll"}
      ],
      memory: [
        {heap_base, heap_bin},
        {mtga_exe_base, <<0x4D, 0x5A>>}
      ]
    )

    # Plumb through the Reader chunk_size/self-check knobs via app env so
    # the worker can read them without its own args plumbing.
    Application.put_env(:scry_2, :collection_reader_opts,
      chunk_size: heap_size,
      scanner: [min_run: 50],
      min_scan_entries: 50
    )

    on_exit(fn -> Application.delete_env(:scry_2, :collection_reader_opts) end)

    assert :ok = perform_job(RefreshJob, %{"trigger" => "manual"})

    snapshot = Collection.current()
    assert snapshot.card_count == 60
    assert snapshot.reader_confidence == "fallback_scan"
  end

  test "broadcasts :refresh_failed when MTGA isn't running" do
    Collection.enable_reader!()
    TestBackend.set_fixture(processes: [])

    Scry2.Topics.subscribe(Scry2.Topics.collection_snapshots())

    assert {:discard, {:error, :mtga_not_running}} =
             perform_job(RefreshJob, %{"trigger" => "manual"})

    assert_receive {:refresh_failed, :mtga_not_running}
  end
end
