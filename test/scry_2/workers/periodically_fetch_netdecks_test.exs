defmodule Scry2.Workers.PeriodicallyFetchNetdecksTest do
  use Scry2.DataCase, async: false
  use Oban.Testing, repo: Scry2.Repo

  import Scry2.TestFactory

  alias Scry2.NetDecking
  alias Scry2.Workers.PeriodicallyFetchNetdecks

  defmodule OkSource do
    @behaviour Scry2.NetDecking.Source
    @impl true
    def fetch,
      do: [%{name: "Mono Red", source_name: "ok", decklist_text: "Deck\n4 Roaring Furnace\n"}]
  end

  defmodule BoomSource do
    @behaviour Scry2.NetDecking.Source
    @impl true
    def fetch, do: raise("boom")
  end

  setup do
    previous = Application.get_env(:scry_2, :netdecking_sources)
    Application.put_env(:scry_2, :netdecking_sources, [BoomSource, OkSource])
    on_exit(fn -> Application.put_env(:scry_2, :netdecking_sources, previous) end)
    :ok
  end

  test "runs every source; a crashing source does not abort the others or the job" do
    create_card(name: "Roaring Furnace")

    assert :ok = perform_job(PeriodicallyFetchNetdecks, %{})

    assert NetDecking.list_decks() != []
  end
end
