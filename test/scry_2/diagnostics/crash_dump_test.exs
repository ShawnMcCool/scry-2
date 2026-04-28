defmodule Scry2.Diagnostics.CrashDumpTest do
  use ExUnit.Case, async: false

  alias Scry2.Diagnostics.CrashDump

  @sample_preamble """
  =erl_crash_dump:0.5
  Tue Apr 28 23:51:01 2026
  Slogan: Kernel pid terminated (application_controller) ("{application_terminated,scry_2,shutdown}")
  System version: Erlang/OTP 28 [erts-16.4] [source] [64-bit] [smp:12:12] [ds:12:12:10] [async-threads:1] [jit:ns]
  Taints: crypto,asn1rt_nif,Elixir.Exqlite.Sqlite3NIF
  Atoms: 52083
  """

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "scry2_crashdump_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)

    on_exit(fn ->
      File.rm_rf(tmp)
      :persistent_term.erase({CrashDump, :latest_summary})
    end)

    {:ok, tmp: tmp}
  end

  describe "parse/1" do
    test "extracts timestamp, slogan, and system version", %{tmp: tmp} do
      path = Path.join(tmp, "erl_crash.dump")
      File.write!(path, @sample_preamble)

      summary = CrashDump.parse(path)

      assert summary.crashed_at_raw == "Tue Apr 28 23:51:01 2026"
      assert summary.crashed_at == ~U[2026-04-28 23:51:01Z]

      assert summary.slogan ==
               "Kernel pid terminated (application_controller) (\"{application_terminated,scry_2,shutdown}\")"

      assert summary.system_version =~ "Erlang/OTP 28"
    end

    test "missing file yields nils, not a crash", %{tmp: tmp} do
      summary = CrashDump.parse(Path.join(tmp, "does-not-exist.dump"))

      assert summary == %{
               crashed_at: nil,
               crashed_at_raw: nil,
               slogan: nil,
               system_version: nil,
               archived_path: nil
             }
    end

    test "malformed preamble returns nils for the missing fields", %{tmp: tmp} do
      path = Path.join(tmp, "erl_crash.dump")
      File.write!(path, "garbage that doesn't match any pattern\n")

      summary = CrashDump.parse(path)

      assert summary.crashed_at == nil
      assert summary.slogan == nil
      assert summary.system_version == nil
    end
  end

  describe "init!/1 archive + cache flow" do
    test "no-op when no previous dump exists", %{tmp: tmp} do
      dump_path = Path.join([tmp, "log", "erl_crash.dump"])
      :persistent_term.erase({CrashDump, :latest_summary})

      assert :ok = CrashDump.init!(dump_path)
      assert CrashDump.latest_summary() == nil
      # ERL_CRASH_DUMP env should now point at the requested path
      assert System.get_env("ERL_CRASH_DUMP") == dump_path
    end

    test "archives an existing dump and caches its summary", %{tmp: tmp} do
      log_dir = Path.join(tmp, "log")
      File.mkdir_p!(log_dir)
      dump_path = Path.join(log_dir, "erl_crash.dump")
      File.write!(dump_path, @sample_preamble)

      :persistent_term.erase({CrashDump, :latest_summary})
      assert :ok = CrashDump.init!(dump_path)

      # Original dump renamed aside
      refute File.exists?(dump_path)
      archived = log_dir |> Path.join("erl_crash-*.dump") |> Path.wildcard()
      assert length(archived) == 1
      [archived_path] = archived

      summary = CrashDump.latest_summary()
      assert summary.crashed_at == ~U[2026-04-28 23:51:01Z]
      assert summary.slogan =~ "application_terminated"
      assert summary.archived_path == archived_path
    end

    test "prunes archives beyond the retention cap", %{tmp: tmp} do
      log_dir = Path.join(tmp, "log")
      File.mkdir_p!(log_dir)
      dump_path = Path.join(log_dir, "erl_crash.dump")

      # Seed 10 archived dumps with sortable suffixes (newest last alphabetically)
      Enum.each(1..10, fn i ->
        path =
          Path.join(log_dir, "erl_crash-2026042823510#{String.pad_leading("#{i}", 2, "0")}.dump")

        File.write!(path, "fake")
      end)

      assert :ok = CrashDump.init!(dump_path)

      remaining = log_dir |> Path.join("erl_crash-*.dump") |> Path.wildcard()
      # Cap is 5
      assert length(remaining) == 5
    end
  end
end
