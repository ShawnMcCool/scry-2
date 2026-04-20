defmodule Scry2.SelfUpdate.CheckerJobTest do
  use Scry2.DataCase, async: false
  use Oban.Testing, repo: Scry2.Repo

  alias Scry2.SelfUpdate.CheckerJob
  alias Scry2.SelfUpdate.Storage
  alias Scry2.SelfUpdate.UpdateChecker
  alias Scry2.Topics

  setup do
    UpdateChecker.clear_cache()
    Storage.clear_all!()

    # Thread the Req.Test stub into the worker via application env. Oban's
    # `testing: :inline` mode executes `perform_job/3` in the test process,
    # so a plug named after CheckerJob is found via NimbleOwnership caller
    # lookup. Attempting to ship `req_options` through `:meta` fails because
    # Oban JSON-recodes meta and Plug tuples aren't encodable.
    previous_options = Application.get_env(:scry_2, :self_update_req_options)
    Application.put_env(:scry_2, :self_update_req_options, plug: {Req.Test, CheckerJob})

    on_exit(fn ->
      UpdateChecker.clear_cache()

      if previous_options do
        Application.put_env(:scry_2, :self_update_req_options, previous_options)
      else
        Application.delete_env(:scry_2, :self_update_req_options)
      end
    end)

    :ok
  end

  test "perform/1 stores the result and broadcasts" do
    Req.Test.stub(CheckerJob, fn conn ->
      Req.Test.json(conn, %{
        "tag_name" => "v99.0.0",
        "published_at" => nil,
        "html_url" => "",
        "body" => ""
      })
    end)

    Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_status())

    assert :ok = perform_job(CheckerJob, %{"trigger" => "cron"})

    assert_receive :check_started, 500
    assert_receive {:check_complete, {:ok, %{tag: "v99.0.0"}}}, 500
    assert {:ok, %{tag: "v99.0.0"}} = Storage.latest_known()
  end

  test "perform/1 records and broadcasts rate-limit errors" do
    Req.Test.stub(CheckerJob, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-ratelimit-remaining", "0")
      |> Plug.Conn.put_resp_header("x-ratelimit-reset", "0")
      |> Plug.Conn.resp(403, ~s|{"message":"rate limit"}|)
    end)

    Phoenix.PubSub.subscribe(Scry2.PubSub, Topics.updates_status())

    assert :ok = perform_job(CheckerJob, %{"trigger" => "cron"})

    assert_receive :check_started, 500
    assert_receive {:check_complete, {:error, {:rate_limited, _}}}, 500
  end
end
