defmodule Scry2.Cards.BoosterCollation do
  @moduledoc """
  Maps an MTGA booster `collationId` to its set code (e.g., `100060 →
  "BLB"`, `100052 → "DFT"`).

  The mapping is not stored in MTGA's local SQLite databases — it lives
  in `MTGA_Data/Downloads/ALT/ALT_Booster_*.mtga` (a JSON
  `AssetLookupTree`). The tree's `ALT_Booster.Logo` branch is a
  decision tree where every `Booster_CollationMapping` evaluator (with
  `ExpectedValues: [collation_ids]`) eventually leads to a payload
  whose `TextureRef.RelativePath` matches `SetLogo_<SET>(_<LANG>)?.png`.
  Walking that tree yields the entire `collation_id → set_code` table.

  ## Pipeline

  1. `find_json_path/1` — locate the ALT_Booster file in `MTGA_Data/Downloads/ALT/`
  2. `parse/1` — parse JSON and walk the Logo branch
  3. `lookup/1` — public lookup (lazy-loaded, cached in
     `:persistent_term`)
  4. `reload/0` — force re-parse (called after MTGA updates)

  This module is intentionally pure (no DB, no GenServer). The lookup
  table is small (~70 entries) and stable — one in-memory map shared
  across the BEAM is all we need.
  """

  require Scry2.Log, as: Log

  @persistent_key {__MODULE__, :mappings}

  @doc """
  Parses an ALT_Booster JSON string and returns a flat list of
  `{collation_id, set_code}` tuples.

  Returns `[]` for malformed or empty input. Mappings are
  deduplicated — if a single collation_id reaches multiple SetLogo
  paths (e.g., via a list of language variants), only the first
  unique set_code is kept.
  """
  @spec parse(String.t()) :: [{integer(), String.t()}]
  def parse(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"ALT_Booster.Logo" => %{"Nodes" => nodes, "Connections" => connections}}}
      when is_list(nodes) and is_list(connections) ->
        node_index = Map.new(nodes, fn n -> {n["NodeId"], n} end)
        conn_index = build_connection_index(connections)

        nodes
        |> Enum.filter(&collation_evaluator?/1)
        |> Enum.flat_map(&extract_mappings(&1, node_index, conn_index))
        |> Enum.uniq()

      _ ->
        []
    end
  end

  @doc """
  Extracts the bare set code from a `SetLogo_<SET>(_<LANG>)?.png` path.

  Returns nil when the path does not match the SetLogo pattern.
  """
  @spec set_code_from_path(String.t() | nil) :: String.t() | nil
  def set_code_from_path(nil), do: nil

  def set_code_from_path(path) when is_binary(path) do
    case Regex.run(~r/SetLogo_([A-Z0-9]{2,5})(?:_[A-Za-z]{2})?\.png\z/, path) do
      [_, code] -> code
      _ -> nil
    end
  end

  @doc """
  Finds the `ALT_Booster_*.mtga` file in the given directory.
  Returns the full path, or nil if not found.
  """
  @spec find_json_path(String.t()) :: String.t() | nil
  def find_json_path(dir) when is_binary(dir) do
    case Path.wildcard(Path.join(dir, "ALT_Booster_*.mtga")) do
      [path | _] -> path
      [] -> nil
    end
  end

  @doc """
  Returns the set code for a booster `collation_id`, or nil if unknown.

  Lazy-loads the mapping table from disk on first call, caches it in
  `:persistent_term`. Subsequent calls are O(log n) map lookups.
  """
  @spec lookup(integer()) :: String.t() | nil
  def lookup(collation_id) when is_integer(collation_id) do
    table()
    |> Map.get(collation_id)
  end

  @doc """
  Force-refreshes the cached mapping table from disk. Call after MTGA
  updates if the app is long-running.
  """
  @spec reload() :: :ok
  def reload do
    :persistent_term.erase(@persistent_key)
    table()
    :ok
  end

  @doc """
  Test helper. Replaces the cached table with the given mapping
  (`%{collation_id => set_code}`). Call from setup blocks. Use
  `put_for_test(%{})` in `on_exit` to clear.

  Not for production use — `:persistent_term` is global, so this
  helper is only safe in tests that don't run async on this module.
  """
  @spec put_for_test(%{integer() => String.t()}) :: :ok
  def put_for_test(mapping) when is_map(mapping) do
    :persistent_term.put(@persistent_key, mapping)
  end

  # ── Internals ──────────────────────────────────────────────────────

  defp table do
    case :persistent_term.get(@persistent_key, :uninitialized) do
      :uninitialized ->
        loaded = load_from_disk()
        :persistent_term.put(@persistent_key, loaded)
        loaded

      cached ->
        cached
    end
  end

  defp load_from_disk do
    with dir when is_binary(dir) <- default_alt_dir(),
         json_path when is_binary(json_path) <- find_json_path(dir),
         {:ok, json} <- File.read(json_path) do
      mappings = parse(json) |> Map.new()
      Log.info(:importer, "booster collations: loaded #{map_size(mappings)} mappings")
      mappings
    else
      _ ->
        Log.warning(
          :importer,
          "booster collations: ALT_Booster file not found, lookup will return nil"
        )

        %{}
    end
  end

  defp default_alt_dir do
    case Enum.find(Scry2.Platform.mtga_raw_dir_candidates(), &File.dir?/1) do
      nil ->
        nil

      raw_dir ->
        # ALT/ is a sibling of Raw/ under MTGA_Data/Downloads/
        alt_dir = Path.join(Path.dirname(raw_dir), "ALT")
        if File.dir?(alt_dir), do: alt_dir
    end
  end

  defp build_connection_index(connections) do
    Enum.reduce(connections, %{}, fn %{"Parent" => parent, "Child" => child}, acc ->
      Map.put(acc, parent, child)
    end)
  end

  defp collation_evaluator?(%{
         "EvaluatorType" => "AssetLookupTree.Evaluators.General.Booster_CollationMapping"
       }),
       do: true

  defp collation_evaluator?(_), do: false

  defp extract_mappings(evaluator_node, node_index, conn_index) do
    expected_values = get_in(evaluator_node, ["Evaluator", "ExpectedValues"]) || []
    set_code = follow_to_set_code(evaluator_node["NodeId"], node_index, conn_index)

    case set_code do
      nil -> []
      code -> Enum.map(expected_values, fn cid -> {cid, code} end)
    end
  end

  # Walk the connection tree from a starting node until we reach a
  # payload with a SetLogo TextureRef. Prefer en-US for language splits;
  # for list children, take the first that resolves to a set code.
  defp follow_to_set_code(node_id, node_index, conn_index) do
    follow_to_set_code(node_id, node_index, conn_index, %{})
  end

  defp follow_to_set_code(nil, _node_index, _conn_index, _seen), do: nil

  defp follow_to_set_code(node_id, node_index, conn_index, seen) do
    if Map.has_key?(seen, node_id) do
      nil
    else
      seen = Map.put(seen, node_id, true)
      node = Map.get(node_index, node_id)
      path = get_in(node || %{}, ["Payload", "TextureRef", "RelativePath"])

      case set_code_from_path(path) do
        code when is_binary(code) ->
          code

        nil ->
          conn_index
          |> Map.get(node_id)
          |> resolve_child()
          |> Enum.find_value(&follow_to_set_code(&1, node_index, conn_index, seen))
      end
    end
  end

  # Connection child shapes: single string, list, or language-keyed map.
  defp resolve_child(nil), do: []
  defp resolve_child(child) when is_binary(child), do: [child]
  defp resolve_child(child) when is_list(child), do: child

  defp resolve_child(child) when is_map(child) do
    case Map.get(child, "en-US") do
      nil -> Map.values(child)
      en_us -> [en_us]
    end
  end
end
