defmodule Scry2.Metagame.FetchDefinitionsTest do
  use Scry2.DataCase, async: false
  use Oban.Testing, repo: Scry2.Repo

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
  test "an update enqueues the reclassify worker", %{tmp_dir: tmp_dir} do
    tarball = tarball(tmp_dir, archetypes: %{"Test.json" => @archetype_json})
    stub_download(tarball)

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, :updated} =
               FetchDefinitions.run(req_options: [plug: {Req.Test, FetchDefinitions}])

      assert_enqueued(worker: Scry2.Workers.ReclassifyArchetypes)
    end)
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

  @tag :tmp_dir
  test "extracts and applies every supported format from one tarball", %{tmp_dir: tmp_dir} do
    tarball =
      multi_format_tarball(tmp_dir, %{
        "Standard" => %{"Standard.json" => @archetype_json},
        "Modern" => %{"Modern.json" => @archetype_json}
      })

    stub_download(tarball)

    assert {:ok, :updated} =
             FetchDefinitions.run(req_options: [plug: {Req.Test, FetchDefinitions}])

    assert [%{name: "Test Archetype"}] = Metagame.definitions("Standard").archetypes
    assert [%{name: "Test Archetype"}] = Metagame.definitions("Modern").archetypes
  end

  @tag :tmp_dir
  test "a format entirely absent from the tarball is skipped, not treated as failure", %{
    tmp_dir: tmp_dir
  } do
    tarball =
      multi_format_tarball(tmp_dir, %{"Standard" => %{"Standard.json" => @archetype_json}})

    stub_download(tarball)

    assert {:ok, :updated} =
             FetchDefinitions.run(req_options: [plug: {Req.Test, FetchDefinitions}])

    assert Metagame.definitions("Standard").archetypes != []
    # Pioneer had no folder in this tarball at all — no vendored seed exists
    # for it either, so it stays empty rather than erroring the whole run.
    assert Metagame.definitions("Pioneer").archetypes == []
  end

  @tag :tmp_dir
  test "a format that degrades to fallback-only in one fetch keeps its prior archetypes, not wiped",
       %{tmp_dir: tmp_dir} do
    # Seed Modern with a real archetype first.
    Metagame.replace_definitions!("Modern", %{
      definitions: [
        %{
          key: "Existing",
          kind: "archetype",
          name: "Existing Archetype",
          include_color_in_name: false,
          conditions: [%{"type" => "InMainboard", "cards" => ["Some Card"]}],
          variants: [],
          common_cards: []
        }
      ],
      overrides: []
    })

    # This fetch's tarball has real Standard archetypes, but Modern's folder
    # only has a Fallbacks file — no Archetypes/ at all for Modern this time.
    root_standard = "MTGOFormatData-main/Formats/Standard"
    root_modern = "MTGOFormatData-main/Formats/Modern"

    entries = [
      {~c"#{root_standard}/Archetypes/Standard.json", @archetype_json},
      {~c"#{root_modern}/Fallbacks/Goodstuff.json", @fallback_json}
    ]

    path = Path.join(tmp_dir, "definitions.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    tarball = File.read!(path)

    stub_download(tarball)

    assert {:ok, :updated} =
             FetchDefinitions.run(req_options: [plug: {Req.Test, FetchDefinitions}])

    assert [%{name: "Test Archetype"}] = Metagame.definitions("Standard").archetypes
    # Modern's real archetype from before this fetch must survive — not
    # silently replaced by the fallback-only data this fetch produced for it.
    assert [%{name: "Existing Archetype"}] = Metagame.definitions("Modern").archetypes
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

  defp multi_format_tarball(tmp_dir, archetypes_by_format) do
    entries =
      Enum.flat_map(archetypes_by_format, fn {format, archetypes} ->
        root = "MTGOFormatData-main/Formats/#{format}"

        Enum.map(archetypes, fn {file, content} ->
          {~c"#{root}/Archetypes/#{file}", content}
        end)
      end)

    path = Path.join(tmp_dir, "definitions.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    File.read!(path)
  end
end
