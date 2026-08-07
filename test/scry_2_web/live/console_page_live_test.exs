defmodule Scry2Web.ConsolePageLiveTest do
  use Scry2Web.ConnCase
  import Phoenix.LiveViewTest

  alias Scry2.Console
  alias Scry2.Console.{Entry, Filter}

  setup do
    # The Buffer is an application-wide GenServer — tests share it. Reset
    # the filter to defaults before each test so assertions about filter
    # state are deterministic. Buffer contents are exercised directly in
    # Scry2.Console.RecentEntriesTest and don't need isolation here.
    Console.update_filter(Filter.new_with_defaults())
    :ok
  end

  defp entry(id, overrides) do
    defaults = %{
      id: id,
      timestamp: DateTime.utc_now(),
      level: :info,
      component: :ingester,
      message: "entry #{id}"
    }

    Entry.new(Map.merge(defaults, Map.new(overrides)))
  end

  # The log list was once embedded in every page as a sticky drawer, which put
  # ~2 MB of markup and 8,000 DOM nodes on every page load — the dominant cost
  # of a page render. It must stay scoped to /console.
  describe "the log list is not embedded in ordinary pages" do
    test "dashboard does not render the log list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      refute has_element?(view, "#console-entries")
    end

    test "matches page does not render the log list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/matches")
      refute has_element?(view, "#console-entries")
    end

    test "decks page does not render the log list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/decks")
      refute has_element?(view, "#console-entries")
    end
  end

  describe "/console full-page route mount" do
    test "renders the chip row, log list, and search input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/console")

      assert has_element?(view, "#console-page")
      assert has_element?(view, "#console-entries")
      assert has_element?(view, "#console-search-input")

      # Chip row shows app components.
      assert has_element?(view, "button[phx-value-component=\"ingester\"]")
      assert has_element?(view, "button[phx-value-component=\"ecto\"]")
    end
  end

  describe "/console event handling" do
    test "toggle_component flips visibility via the Console facade", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/console")

      assert Console.get_filter().components[:ecto] == :hide

      view
      |> element("button[phx-value-component=\"ecto\"]")
      |> render_click()

      assert Console.get_filter().components[:ecto] == :show
    end

    test "set_level updates the level floor", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/console")

      view
      |> element("button[phx-value-level=\"error\"]")
      |> render_click()

      assert Console.get_filter().level == :error
    end

    test "search event updates the filter search string", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/console")

      view
      |> element("#console-search-input")
      |> render_keyup(%{"value" => "needle"})

      assert Console.get_filter().search == "needle"
    end

    test "toggle_pause flips the paused assign", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/console")

      # Click the pause button in the footer.
      view |> element("button", "pause") |> render_click()

      # After pause, the same button should now read "resume".
      assert has_element?(view, "button", "resume")
    end
  end

  describe "/console log_entry broadcasts" do
    test "broadcast entries appear in the stream", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/console")

      fresh = entry(999_001, message: "deterministic broadcast test entry")
      Phoenix.PubSub.broadcast(Scry2.PubSub, "console:logs", {:log_entry, fresh})

      # Force the LV to drain its mailbox before asserting.
      _ = render(view)

      assert render(view) =~ "deterministic broadcast test entry"
    end
  end
end
