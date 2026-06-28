defmodule Scry2Web.HealthController do
  @moduledoc """
  Plain HTTP readiness probe at `GET /health`.

  Returns `200` with `{"status":"ok",...}` when the database is reachable and
  all migrations are applied; `503` otherwise. Lives outside the browser
  pipeline and the first-run setup gate so it answers during boot, first-run,
  and while migrations are still running.
  """
  use Scry2Web, :controller

  alias Scry2.Readiness

  def show(conn, _params) do
    result = Readiness.check()
    code = if result.status == :ok, do: 200, else: 503

    conn
    |> put_status(code)
    |> json(result)
  end
end
