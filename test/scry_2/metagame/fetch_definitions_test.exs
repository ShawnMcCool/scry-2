defmodule Scry2.Metagame.FetchDefinitionsTest do
  use Scry2.DataCase, async: false

  @moduletag :capture_log

  alias Scry2.Metagame
  alias Scry2.Metagame.FetchDefinitions

  @archetype_json ~s({"Name": "Test Archetype", "IncludeColorInName": false,
                      "Conditions": [{"Type": "InMainboard", "Cards": ["Test Card"]}]})
  @fallback_json ~s({"Name": "Goodstuff", "IncludeColorInName": false, "CommonCards": ["Common Card"]})
  @overrides_json ~s({"Lands": [{"Name": "Odd Land", "Color": "WU"}], "NonLands": null})

  @tag :tmp_dir
  test "replaces definitions from the upstream tarball and reports change state", %{
    tmp_dir: tmp_dir
  } do
    tarball = tarball(tmp_dir, archetypes: %{"Test.json" => @archetype_json})
    stub_download(tarball)

    Scry2.Topics.subscribe(Scry2.Topics.metagame_updates())

    assert {:ok, :updated} =
             FetchDefinitions.run(req_options: [plug: {Req.Test, FetchDefinitions}])

    assert_receive {:definitions_updated, "Standard"}

    definitions = Metagame.definitions("Standard")
    assert [%{name: "Test Archetype"}] = definitions.archetypes
    assert [%{name: "Goodstuff"}] = definitions.fallbacks
    assert definitions.land_overrides == %{"Odd Land" => "WU"}

    assert {:ok, :unchanged} =
             FetchDefinitions.run(req_options: [plug: {Req.Test, FetchDefinitions}])

    refute_receive {:definitions_updated, "Standard"}
  end

  @tag :tmp_dir
  test "skips malformed files without failing the batch", %{tmp_dir: tmp_dir} do
    tarball =
      tarball(tmp_dir, archetypes: %{"Good.json" => @archetype_json, "Bad.json" => "{nope"})

    stub_download(tarball)

    assert {:ok, :updated} =
             FetchDefinitions.run(req_options: [plug: {Req.Test, FetchDefinitions}])

    assert [%{key: "Good"}] = Metagame.definitions("Standard").archetypes
  end

  test "an HTTP error keeps existing definitions" do
    seeded = Metagame.definitions("Standard")
    assert seeded.archetypes != []

    Req.Test.stub(FetchDefinitions, fn conn -> Plug.Conn.resp(conn, 503, "down") end)

    assert {:error, {:http, 503}} =
             FetchDefinitions.run(req_options: [plug: {Req.Test, FetchDefinitions}, retry: false])

    assert Metagame.definitions("Standard").archetypes == seeded.archetypes
  end

  @tag :tmp_dir
  test "a tarball with no archetype definitions is rejected", %{tmp_dir: tmp_dir} do
    tarball = tarball(tmp_dir, archetypes: %{})
    stub_download(tarball)

    seeded = Metagame.definitions("Standard")

    assert {:error, :no_definitions} =
             FetchDefinitions.run(req_options: [plug: {Req.Test, FetchDefinitions}])

    assert Metagame.definitions("Standard").archetypes == seeded.archetypes
  end

  # ── Helpers ─────────────────────────────────────────────────────────

  defp stub_download(tarball) do
    Req.Test.stub(FetchDefinitions, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/x-gzip")
      |> Plug.Conn.resp(200, tarball)
    end)
  end

  defp tarball(tmp_dir, archetypes: archetypes) do
    root = "MTGOFormatData-main/Formats/Standard"

    entries =
      [
        {~c"#{root}/Fallbacks/Goodstuff.json", @fallback_json},
        {~c"#{root}/color_overrides.json", @overrides_json}
      ] ++
        Enum.map(archetypes, fn {file, content} ->
          {~c"#{root}/Archetypes/#{file}", content}
        end)

    path = Path.join(tmp_dir, "definitions.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.read!(path)
  end
end
