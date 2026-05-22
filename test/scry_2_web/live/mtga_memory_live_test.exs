defmodule Scry2Web.MtgaMemoryLiveTest do
  use Scry2Web.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Scry2.MtgaMemory.TestBackend
  alias Scry2.Settings
  alias Scry2.TestFactory, as: Factory

  setup do
    player = Factory.create_player()
    Settings.put!("active_player_id", player.id)
    TestBackend.clear_fixture()
    :ok
  end

  test "renders the reader self-test card with a run button", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/operations/mtga-memory")

    assert has_element?(view, "[data-role='self-test-card']")
    assert has_element?(view, "button", "Run reader self-test")
  end

  test "running the self-test with no MTGA process shows the mtga_not_running diagnosis",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/operations/mtga-memory")

    view |> element("button", "Run reader self-test") |> render_click()

    assert has_element?(
             view,
             "[data-role='self-test-diagnosis'][data-status='mtga_not_running']"
           )

    assert has_element?(view, "#copy-self-test-report")
  end
end
