defmodule Scry2.Workers.ReclassifyArchetypesTest do
  use Scry2.DataCase, async: false
  use Oban.Testing, repo: Scry2.Repo

  import Scry2.TestFactory

  alias Scry2.NetDecking
  alias Scry2.Workers.ReclassifyArchetypes

  test "re-stamps all three consumer contexts" do
    create_card(name: "Lightning Bolt", rarity: "rare", color_identity: "R")

    {:ok, netdeck} =
      NetDecking.import_decklist(%{
        name: "Pre-definitions",
        source_name: "manual",
        decklist_text: "Deck\n4 Lightning Bolt\n"
      })

    assert netdeck.archetype_name == nil

    Scry2.Metagame.replace_definitions!("Standard", %{
      definitions: [
        %{
          key: "Burn",
          kind: "archetype",
          name: "Burn",
          include_color_in_name: false,
          conditions: [%{"type" => "InMainboard", "cards" => ["Lightning Bolt"]}],
          variants: [],
          common_cards: []
        }
      ],
      overrides: []
    })

    assert :ok = perform_job(ReclassifyArchetypes, %{})

    assert NetDecking.get_deck(netdeck.id).archetype_name == "Burn"
  end
end
