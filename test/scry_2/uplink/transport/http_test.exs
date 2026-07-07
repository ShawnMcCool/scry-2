defmodule Scry2.Uplink.Transport.HttpTest do
  use ExUnit.Case, async: true

  alias Scry2.Uplink.Transport.Http

  defp config(stub) do
    %{
      url: "https://server.test/api/ingest",
      token: "secret-token",
      req_options: [plug: {Req.Test, stub}]
    }
  end

  test "POSTs the events with bearer auth and returns :ok on 2xx" do
    Req.Test.stub(HttpTest.Ok, fn conn ->
      assert conn.method == "POST"
      assert ["Bearer secret-token"] = Plug.Conn.get_req_header(conn, "authorization")
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      assert [%{"upload_key" => "r:1:match_created:0"}] = decoded["events"]
      Req.Test.json(conn, %{"ingested" => 1})
    end)

    events = [%{"upload_key" => "r:1:match_created:0", "event_type" => "match_created"}]
    assert :ok = Http.send_batch(config(HttpTest.Ok), events)
  end

  test "returns {:error, {:http_status, code}} on a non-2xx response" do
    Req.Test.stub(HttpTest.Err, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "nope"})
    end)

    assert {:error, {:http_status, 422}} =
             Http.send_batch(config(HttpTest.Err), [%{"upload_key" => "k"}])
  end

  test "returns {:error, reason} on a transport failure" do
    Req.Test.stub(HttpTest.Down, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, _reason} = Http.send_batch(config(HttpTest.Down), [%{"upload_key" => "k"}])
  end
end
