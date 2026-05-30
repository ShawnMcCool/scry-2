defmodule Scry2.PostDeployTasks.Tasks.SynthesisNameMarkupV1Test do
  use Scry2.DataCase

  import Scry2.TestFactory

  alias Scry2.Cards
  alias Scry2.PostDeployTasks
  alias Scry2.PostDeployTasks.Tasks.SynthesisNameMarkupV1

  test "is registered" do
    assert SynthesisNameMarkupV1 in PostDeployTasks.registered_tasks()
  end

  test "run/0 re-synthesises and clears UI markup from existing names" do
    create_mtga_card(arena_id: 67_168, name: "<nobr>Sergeant-at</nobr>-Arms")

    assert SynthesisNameMarkupV1.run() == :ok

    card = Cards.list_by_arena_ids([67_168])[67_168]
    assert card.name == "Sergeant-at-Arms"
  end
end
