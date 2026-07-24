# One-off data repair (2026-07-23): merges duplicate arena_id line entries
# in netdecking_decks.main_deck/sideboard that predate the IngestDecklist
# fix in lib/scry_2/net_decking/ingest_decklist.ex (`to_card_maps/1`).
#
# Root cause: a source (mostly MTGO) can list the same card on two separate
# decklist lines. Cards.resolve_references/1 resolves each line
# independently by design ("never drops a ref"), so duplicate arena_ids
# reached main_deck/sideboard as separate entries instead of one summed
# entry. Every downstream Map.new(arena_id => count) built from that list
# (scoring, buildability cost, archetype-core deltas) silently kept only
# the LAST entry, undercounting the true total — producing bogus cut
# chips on the archetype catalog page and skewed cost/wildcard numbers.
#
# The corruption also broke the corpus's own dedup identity
# (composition_hash + format): two rows that are actually the same 60-card
# list hashed differently pre-merge (each had its own pattern of split
# lines), so they slipped past IngestDecklist's upsert-by-hash check and
# were stored as separate rows. Merging reveals the true shared identity —
# those groups get consolidated to one canonical row (best competitive
# finish wins, via Scry2.NetDecking.Provenance.best_finish_deck/1 — the
# same rule the catalog already uses to credit a cluster's provenance);
# the rest are removed. netdecking_decks has no incoming foreign keys, so
# deleting the redundant rows is safe.
#
# Usage:
#   mix run priv/repo/repair_netdeck_duplicate_lines.exs           # dry run, reports only
#   mix run priv/repo/repair_netdeck_duplicate_lines.exs --apply   # persists the merge + consolidation

alias Scry2.{Decks, Metagame, Repo}
alias Scry2.NetDecking.{Deck, Provenance}

apply? = "--apply" in System.argv()

merge_cards = fn cards ->
  cards
  |> Enum.group_by(& &1["arena_id"], & &1["count"])
  |> Enum.map(fn {arena_id, counts} -> %{"arena_id" => arena_id, "count" => Enum.sum(counts)} end)
end

sorted_pairs = fn cards ->
  cards |> Enum.map(fn c -> {c["arena_id"], c["count"]} end) |> Enum.sort()
end

decks = Repo.all(Deck)

repairs =
  Enum.map(decks, fn deck ->
    main_cards = deck.main_deck["cards"] || []
    side_cards = deck.sideboard["cards"] || []
    merged_main = merge_cards.(main_cards)
    merged_side = merge_cards.(side_cards)

    changed? =
      length(merged_main) != length(main_cards) or length(merged_side) != length(side_cards)

    new_hash = if changed?, do: Decks.composition_hash(merged_main), else: deck.composition_hash

    %{
      deck: deck,
      changed?: changed?,
      merged_main: merged_main,
      merged_side: merged_side,
      new_hash: new_hash
    }
  end)

candidate_groups =
  repairs
  |> Enum.group_by(fn r -> {r.new_hash, r.deck.format} end)
  |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
  |> Enum.map(fn {_key, group} -> group end)

# phash2 is 27-bit — verify actual composition equality before treating a
# hash match as a true duplicate (per Decks.composition_hash's own caveat).
{true_collision_groups, false_positive_groups} =
  Enum.split_with(candidate_groups, fn group ->
    [first | rest] = Enum.map(group, &sorted_pairs.(&1.merged_main))
    Enum.all?(rest, &(&1 == first))
  end)

colliding_ids = true_collision_groups |> List.flatten() |> MapSet.new(& &1.deck.id)
changed = Enum.filter(repairs, & &1.changed?)
safe_to_apply = Enum.reject(changed, &MapSet.member?(colliding_ids, &1.deck.id))

canonical_for = fn group ->
  member_decks = Enum.map(group, & &1.deck)
  Provenance.best_finish_deck(member_decks) || Enum.min_by(member_decks, & &1.id)
end

IO.puts("#{length(decks)} decks scanned.")
IO.puts("#{length(changed)} decks have duplicate arena_id lines to merge.")

IO.puts(
  "#{length(true_collision_groups)} groups (#{MapSet.size(colliding_ids)} decks) are true duplicates of another deck post-merge:"
)

Enum.each(true_collision_groups, fn group ->
  canonical = canonical_for.(group)

  IO.puts(
    "  group of #{length(group)}, canonical -> ##{canonical.id} #{inspect(canonical.pilot)} placement=#{inspect(canonical.placement)}"
  )

  Enum.each(group, fn r ->
    marker = if r.deck.id == canonical.id, do: "KEEP", else: "DELETE"

    IO.puts(
      "    #{marker} ##{r.deck.id} pilot=#{inspect(r.deck.pilot)} event=#{inspect(r.deck.event_name)} date=#{inspect(r.deck.event_date)} placement=#{inspect(r.deck.placement)}"
    )
  end)
end)

if false_positive_groups != [] do
  IO.puts(
    "#{length(false_positive_groups)} hash collisions were NOT true duplicates (phash2 collision) — left untouched:"
  )

  Enum.each(false_positive_groups, fn group ->
    Enum.each(group, fn r -> IO.puts("    ##{r.deck.id} pilot=#{inspect(r.deck.pilot)}") end)
  end)
end

IO.puts("#{length(safe_to_apply)} decks will be merged in place (no identity change).")

if apply? do
  Repo.transaction(fn ->
    Enum.each(safe_to_apply, fn r ->
      stamp =
        Metagame.classification_attrs(
          %{"cards" => r.merged_main},
          %{"cards" => r.merged_side},
          r.deck.format
        )

      changeset =
        Deck.changeset(r.deck, %{
          main_deck: %{"cards" => r.merged_main},
          sideboard: %{"cards" => r.merged_side},
          composition_hash: r.new_hash,
          archetype_name: stamp.archetype_name,
          archetype_variant: stamp.archetype_variant,
          archetype_fallback: stamp.archetype_fallback
        })

      case Repo.update(changeset) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          IO.puts("  FAILED merge ##{r.deck.id}: #{inspect(changeset.errors)}")
      end
    end)

    Enum.each(true_collision_groups, fn group ->
      canonical = canonical_for.(group)
      canonical_repair = Enum.find(group, &(&1.deck.id == canonical.id))

      stamp =
        Metagame.classification_attrs(
          %{"cards" => canonical_repair.merged_main},
          %{"cards" => canonical_repair.merged_side},
          canonical.format
        )

      changeset =
        Deck.changeset(canonical, %{
          main_deck: %{"cards" => canonical_repair.merged_main},
          sideboard: %{"cards" => canonical_repair.merged_side},
          composition_hash: canonical_repair.new_hash,
          archetype_name: stamp.archetype_name,
          archetype_variant: stamp.archetype_variant,
          archetype_fallback: stamp.archetype_fallback
        })

      case Repo.update(changeset) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          IO.puts("  FAILED canonical update ##{canonical.id}: #{inspect(changeset.errors)}")
      end

      group
      |> Enum.reject(&(&1.deck.id == canonical.id))
      |> Enum.each(fn r ->
        case Repo.delete(r.deck) do
          {:ok, _} ->
            :ok

          {:error, changeset} ->
            IO.puts("  FAILED delete ##{r.deck.id}: #{inspect(changeset.errors)}")
        end
      end)
    end)
  end)

  IO.puts(
    "Applied #{length(safe_to_apply)} in-place merges and #{length(true_collision_groups)} consolidations."
  )
else
  IO.puts("Dry run only — rerun with --apply (after stopping the scry-2 service) to persist.")
end
