defmodule Scry2Web.DeckSearchTest do
  use ExUnit.Case, async: true

  alias Scry2Web.DeckSearch
  alias Scry2Web.DeckSearch.Facets

  @candidates [
    %{key: "duress", label: "Duress", count: 3},
    %{key: "llanowar elves", label: "Llanowar Elves", count: 9},
    %{key: "elvish mystic", label: "Elvish Mystic", count: 5},
    %{key: "quandrix cultivator", label: "Quandrix Cultivator", count: 1}
  ]

  defp facets(names, card_keys) do
    %Facets{names: names, card_keys: MapSet.new(card_keys)}
  end

  describe "rank_suggestions/3" do
    test "blank query yields nothing" do
      assert DeckSearch.rank_suggestions(@candidates, "") == []
      assert DeckSearch.rank_suggestions(@candidates, "   ") == []
    end

    test "substring match, prefix matches first, then count desc" do
      assert Enum.map(DeckSearch.rank_suggestions(@candidates, "elv"), & &1.key) ==
               ["elvish mystic", "llanowar elves"]
    end

    test "case-insensitive" do
      assert Enum.map(DeckSearch.rank_suggestions(@candidates, "DURESS"), & &1.key) == ["duress"]
    end

    test "caps at limit" do
      many = Enum.map(1..20, fn n -> %{key: "card #{n}", label: "Card #{n}", count: n} end)
      assert length(DeckSearch.rank_suggestions(many, "card")) == 8
      assert length(DeckSearch.rank_suggestions(many, "card", 3)) == 3
    end
  end

  describe "match?/2" do
    test "a blank search matches everything" do
      assert DeckSearch.match?(DeckSearch.new(), facets(["Mono Black"], ["duress"]))
    end

    test "text matches any of the facet names, case-insensitively" do
      search = %DeckSearch{query: "midrange"}

      assert DeckSearch.match?(search, facets(["Mono Black", "Mono Black Midrange"], []))
      refute DeckSearch.match?(search, facets(["Izzet Prowess"], []))
    end

    test "nil names never match" do
      refute DeckSearch.match?(%DeckSearch{query: "mono"}, facets([nil], []))
    end

    test "card selection is membership on the facet's card keys" do
      search = %DeckSearch{card: %{key: "duress", label: "Duress"}}

      assert DeckSearch.match?(search, facets(["Mono Black"], ["duress"]))
      refute DeckSearch.match?(search, facets(["Mono Black"], ["swamp"]))
    end

    test "text and card filters are ANDed" do
      search = %DeckSearch{query: "mono", card: %{key: "duress", label: "Duress"}}

      assert DeckSearch.match?(search, facets(["Mono Black"], ["duress"]))
      refute DeckSearch.match?(search, facets(["Izzet Prowess"], ["duress"]))
      refute DeckSearch.match?(search, facets(["Mono Black"], ["swamp"]))
    end
  end

  describe "filtering?/1" do
    test "false only when nothing is typed and no card is chosen" do
      refute DeckSearch.filtering?(DeckSearch.new())
      assert DeckSearch.filtering?(%DeckSearch{query: "mono"})
      assert DeckSearch.filtering?(%DeckSearch{card: %{key: "duress", label: "Duress"}})
    end

    test "whitespace alone is not a filter" do
      refute DeckSearch.filtering?(%DeckSearch{query: "   "})
    end
  end

  describe "name_typed/3" do
    test "applies the typed value and ranks suggestions" do
      search = DeckSearch.name_typed(DeckSearch.new(), %{"value" => "elv"}, @candidates)

      assert search.query == "elv"
      assert Enum.map(search.name_suggestions, & &1.key) == ["elvish mystic", "llanowar elves"]
    end

    test "Escape keeps the typed value but closes the suggestions" do
      search = DeckSearch.name_typed(DeckSearch.new(), %{"value" => "elv"}, @candidates)

      escaped =
        DeckSearch.name_typed(search, %{"key" => "Escape", "value" => "elv"}, @candidates)

      assert escaped.query == "elv"
      assert escaped.name_suggestions == []
    end

    test "an ordinary keystroke is not treated as Escape" do
      search =
        DeckSearch.name_typed(DeckSearch.new(), %{"key" => "v", "value" => "elv"}, @candidates)

      assert search.name_suggestions != []
    end
  end

  describe "card_typed/3 and card picking" do
    test "typing ranks card suggestions without touching the applied filter" do
      search = DeckSearch.card_typed(DeckSearch.new(), %{"value" => "dur"}, @candidates)

      assert search.card_query == "dur"
      assert search.card == nil
      assert Enum.map(search.card_suggestions, & &1.key) == ["duress"]
    end

    test "Escape keeps the typed value but closes the suggestions" do
      search =
        DeckSearch.new()
        |> DeckSearch.card_typed(%{"value" => "dur"}, @candidates)
        |> DeckSearch.card_typed(%{"key" => "Escape", "value" => "dur"}, @candidates)

      assert search.card_query == "dur"
      assert search.card_suggestions == []
    end

    test "picking a card applies it and clears the card box" do
      search =
        DeckSearch.new()
        |> DeckSearch.card_typed(%{"value" => "dur"}, @candidates)
        |> DeckSearch.card_picked(%{"key" => "duress", "label" => "Duress"})

      assert search.card == %{key: "duress", label: "Duress"}
      assert search.card_query == ""
      assert search.card_suggestions == []
    end

    test "clearing drops the applied card" do
      search =
        %DeckSearch{card: %{key: "duress", label: "Duress"}}
        |> DeckSearch.card_cleared()

      assert search.card == nil
    end
  end

  describe "name_picked/2" do
    test "fills the query with the chosen label and closes suggestions" do
      search =
        DeckSearch.new()
        |> DeckSearch.name_typed(%{"value" => "elv"}, @candidates)
        |> DeckSearch.name_picked(%{"label" => "Elvish Mystic"})

      assert search.query == "Elvish Mystic"
      assert search.name_suggestions == []
    end
  end

  describe "dismissed/1" do
    test "closes both suggestion lists and keeps the applied filters" do
      search =
        %DeckSearch{
          query: "mono",
          card: %{key: "duress", label: "Duress"},
          name_suggestions: @candidates,
          card_suggestions: @candidates
        }
        |> DeckSearch.dismissed()

      assert search.name_suggestions == []
      assert search.card_suggestions == []
      assert search.query == "mono"
      assert search.card == %{key: "duress", label: "Duress"}
    end
  end

  describe "card_candidates/1" do
    test "maps a DeckList card index into search candidates" do
      index = [%{key: "duress", name: "Duress", count: 3}]

      assert DeckSearch.card_candidates(index) == [%{key: "duress", label: "Duress", count: 3}]
    end
  end
end
