defmodule Scry2Web.HealthControllerTest do
  use Scry2Web.ConnCase, async: false

  test "GET /health returns 200 with readiness JSON when the app is ready", %{conn: conn} do
    conn = get(conn, ~p"/health")

    assert conn.status == 200
    body = json_response(conn, 200)
    assert body["status"] == "ok"
    assert body["database"] == "ok"
    assert body["migrations"]["up_to_date"] == true
    assert body["migrations"]["pending"] == 0
  end
end
