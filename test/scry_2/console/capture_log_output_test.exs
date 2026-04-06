defmodule Scry2.Console.CaptureLogOutputTest do
  use ExUnit.Case, async: true

  alias Scry2.Console.{Entry, CaptureLogOutput}

  describe "build_entry/3 — level normalization" do
    test "collapses Erlang levels to the four canonical levels" do
      assert CaptureLogOutput.build_entry(:debug, {:string, "x"}, %{}).level == :debug
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, %{}).level == :info
      assert CaptureLogOutput.build_entry(:notice, {:string, "x"}, %{}).level == :info
      assert CaptureLogOutput.build_entry(:warning, {:string, "x"}, %{}).level == :warning
      assert CaptureLogOutput.build_entry(:warn, {:string, "x"}, %{}).level == :warning
      assert CaptureLogOutput.build_entry(:error, {:string, "x"}, %{}).level == :error
      assert CaptureLogOutput.build_entry(:critical, {:string, "x"}, %{}).level == :error
      assert CaptureLogOutput.build_entry(:alert, {:string, "x"}, %{}).level == :error
      assert CaptureLogOutput.build_entry(:emergency, {:string, "x"}, %{}).level == :error
    end

    test "unknown levels default to :info" do
      assert CaptureLogOutput.build_entry(:made_up, {:string, "x"}, %{}).level == :info
    end
  end

  describe "build_entry/3 — component classification" do
    test "explicit :component metadata wins over module classification" do
      meta = %{component: :ingester, mfa: {Phoenix.Socket, :connect, 2}}
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, meta).component == :ingester
    end

    test "Phoenix.LiveView modules classify as :live_view" do
      meta = %{mfa: {Phoenix.LiveView.Channel, :handle_info, 2}}
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, meta).component == :live_view
    end

    test "Phoenix.* classifies as :phoenix" do
      meta = %{mfa: {Phoenix.Endpoint, :call, 2}}
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, meta).component == :phoenix
    end

    test "Ecto.* classifies as :ecto" do
      meta = %{mfa: {Ecto.Repo.Queryable, :all, 2}}
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, meta).component == :ecto
    end

    test "Exqlite.* classifies as :ecto (SQLite driver)" do
      meta = %{mfa: {Exqlite.Connection, :handle_execute, 4}}
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, meta).component == :ecto
    end

    test "DBConnection.* classifies as :ecto" do
      meta = %{mfa: {DBConnection.Holder, :checkout, 2}}
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, meta).component == :ecto
    end

    test "unrecognized modules classify as :system" do
      meta = %{mfa: {:gen_server, :call, 2}}
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, meta).component == :system
    end

    test "no module meta classifies as :system" do
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, %{}).component == :system
    end
  end

  describe "build_entry/3 — message rendering" do
    test "renders {:string, iodata}" do
      entry = CaptureLogOutput.build_entry(:info, {:string, ["hello ", "world"]}, %{})
      assert entry.message == "hello world"
    end

    test "renders {:report, map}" do
      entry = CaptureLogOutput.build_entry(:info, {:report, %{foo: "bar"}}, %{})
      assert entry.message =~ "foo"
      assert entry.message =~ "bar"
    end

    test "renders {format, args} tuples" do
      entry = CaptureLogOutput.build_entry(:info, {~c"~p is ~B", [:count, 42]}, %{})
      assert entry.message =~ "42"
    end

    test "strips ANSI escape sequences" do
      ansi = "\e[31mred text\e[0m"
      entry = CaptureLogOutput.build_entry(:info, {:string, ansi}, %{})
      assert entry.message == "red text"
    end

    test "truncates messages longer than 2000 bytes" do
      long_message = String.duplicate("a", 2_500)
      entry = CaptureLogOutput.build_entry(:info, {:string, long_message}, %{})
      assert String.length(entry.message) <= 2_005
      assert String.ends_with?(entry.message, "...")
    end
  end

  describe "build_entry/3 — module and metadata" do
    test "extracts module from meta[:mfa]" do
      meta = %{mfa: {Scry2.Cards, :upsert_card!, 1}}
      assert CaptureLogOutput.build_entry(:info, {:string, "x"}, meta).module == Scry2.Cards
    end

    test "prunes metadata to scalar allowlist" do
      meta = %{
        component: :ingester,
        mfa: {Scry2.Cards, :upsert_card!, 1},
        file: "lib/scry_2/cards.ex",
        line: 42,
        # Should be dropped
        big_struct: %{pid: self(), private: "data"}
      }

      entry = CaptureLogOutput.build_entry(:info, {:string, "x"}, meta)

      assert entry.metadata[:component] == :ingester
      assert entry.metadata[:mfa] == "Scry2.Cards.upsert_card!/1"
      assert entry.metadata[:file] == "lib/scry_2/cards.ex"
      assert entry.metadata[:line] == 42
      refute Map.has_key?(entry.metadata, :big_struct)
    end
  end

  describe "build_entry/3 — id and timestamp" do
    test "generates monotonically increasing ids" do
      a = CaptureLogOutput.build_entry(:info, {:string, "x"}, %{})
      b = CaptureLogOutput.build_entry(:info, {:string, "x"}, %{})
      assert b.id > a.id
    end

    test "sets timestamp to current UTC" do
      before_ts = DateTime.utc_now()
      entry = CaptureLogOutput.build_entry(:info, {:string, "x"}, %{})
      after_ts = DateTime.utc_now()

      assert DateTime.compare(entry.timestamp, before_ts) != :lt
      assert DateTime.compare(entry.timestamp, after_ts) != :gt
    end

    test "returns a fully populated %Entry{}" do
      entry = CaptureLogOutput.build_entry(:info, {:string, "x"}, %{})
      assert %Entry{id: id, level: :info, component: :system, message: "x"} = entry
      assert is_integer(id)
    end
  end
end
