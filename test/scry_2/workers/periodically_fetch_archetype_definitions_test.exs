defmodule Scry2.Workers.PeriodicallyFetchArchetypeDefinitionsTest do
  use Scry2.DataCase, async: false
  use Oban.Testing, repo: Scry2.Repo

  alias Scry2.Metagame
  alias Scry2.Workers.PeriodicallyFetchArchetypeDefinitions

  setup do
    Application.put_env(:scry_2, :metagame_fetch_req_options,
      plug: {Req.Test, Scry2.Metagame.FetchDefinitions},
      retry: false
    )

    on_exit(fn -> Application.delete_env(:scry_2, :metagame_fetch_req_options) end)
  end

  @tag :tmp_dir
  test "fetches and applies definitions", %{tmp_dir: tmp_dir} do
    archetype = ~s({"Name": "Worker Test", "IncludeColorInName": false,
                    "Conditions": [{"Type": "InMainboard", "Cards": ["A"]}]})

    root = "MTGOFormatData-main/Formats/Standard"
    path = Path.join(tmp_dir, "definitions.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        [{~c"#{root}/Archetypes/WorkerTest.json", archetype}],
        [:compressed]
      )

    tarball = File.read!(path)

    Req.Test.stub(Scry2.Metagame.FetchDefinitions, fn conn ->
      Plug.Conn.resp(conn, 200, tarball)
    end)

    assert :ok = perform_job(PeriodicallyFetchArchetypeDefinitions, %{})
    assert [%{name: "Worker Test"}] = Metagame.definitions("Standard").archetypes
  end

  test "an HTTP failure fails the job without touching definitions" do
    seeded = Metagame.definitions("Standard")

    Req.Test.stub(Scry2.Metagame.FetchDefinitions, fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    assert {:error, {:http, 500}} = perform_job(PeriodicallyFetchArchetypeDefinitions, %{})
    assert Metagame.definitions("Standard").archetypes == seeded.archetypes
  end
end
