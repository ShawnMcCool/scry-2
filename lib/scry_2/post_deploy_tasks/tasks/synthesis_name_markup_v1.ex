defmodule Scry2.PostDeployTasks.Tasks.SynthesisNameMarkupV1 do
  @moduledoc """
  Re-runs `Scry2.Cards.Synthesize.run/0` after the fix that strips MTGA
  UI markup from MTGA-only card names (`<nobr>…</nobr>` non-breaking
  wrappers and `<sprite="…">` Alchemy-rebalance icons — see
  `Scry2.Cards.Synthesize.MergeFields.strip_mtga_markup/1`).

  Without this re-run, existing `cards_cards` rows synthesised before the
  fix keep the raw markup in their `name`, which renders literally in the
  Collection grid, the card browser, search, and deck/clipboard exports
  (e.g. `<nobr>Sergeant-at</nobr>-Arms`). Re-synthesis rewrites every row
  with the cleaned name. The periodic synthesis worker would eventually
  clear it too, but this task makes it happen on first boot after the
  upgrade.
  """

  @behaviour Scry2.PostDeployTasks.Task

  alias Scry2.Cards.Synthesize

  @impl true
  def task_id, do: "synthesis.name_markup_v1"

  @impl true
  def description do
    "Re-run card synthesis to strip MTGA UI markup (<nobr>, <sprite>) " <>
      "from card names. Required after upgrading to clear literal markup " <>
      "like `<nobr>Sergeant-at</nobr>-Arms` from the Collection grid, card " <>
      "browser, search, and deck exports."
  end

  @impl true
  def run do
    {:ok, _stats} = Synthesize.run([])
    :ok
  end
end
