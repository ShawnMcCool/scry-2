defmodule Scry2Web.SetupGateTest do
  use Scry2Web.ConnCase
  import Phoenix.LiveViewTest

  alias Scry2.SetupFlow

  # ConnCase defaults to mark_completed! so existing tests work. Tests in
  # this module specifically need the tour active, so reset it here.
  setup do
    :ok = SetupFlow.reset!()
    :ok
  end

  describe "on_mount/4" do
    test "redirects to /setup when SetupFlow.required? is true", %{conn: conn} do
      # Test sandbox has no player log, no cards, no events, and we just
      # reset the completed flag — SetupFlow.required? is true.
      assert SetupFlow.required?()

      assert {:error, {:redirect, %{to: "/setup"}}} = live(conn, ~p"/")
    end

    test "passes through when SetupFlow has been marked completed", %{conn: conn} do
      :ok = SetupFlow.mark_completed!()
      refute SetupFlow.required?()

      {:ok, _view, _html} = live(conn, ~p"/")
    end

    test "/setup itself is never gated", %{conn: conn} do
      assert SetupFlow.required?()
      {:ok, _view, _html} = live(conn, ~p"/setup")
    end
  end
end
