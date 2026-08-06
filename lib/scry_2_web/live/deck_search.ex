defmodule Scry2Web.DeckSearch do
  @moduledoc """
  The one deck-catalog search: narrow a set of decks by typed text and by a
  chosen card. Both catalogs use it — the netdeck corpus (`NetdecksLive`) and
  the player's deck library (`DecksLive`) — so ranking, matching, and the
  Escape handling have a single implementation.

  The struct is the whole search-bar state, held as one assign: the applied
  filters (`query`, `card`), the card box's in-progress text (`card_query`),
  and the two open suggestion lists. A LiveView wires one event per function:

      def handle_event("search_name", params, socket) do
        {:noreply,
         assign(socket,
           search: DeckSearch.name_typed(socket.assigns.search, params, name_candidates(socket))
         )}
      end

  Each page supplies its own suggestion candidates — `card_candidates/1`
  adapts any context's `Scry2.DeckList.card_index/2`, while name candidates
  are page-specific (a netdeck's archetype labels weighted by decklist count
  are not the library's deck names) — and asks `match?/2` per row.

  Escape arrives through the same debounced keyup as ordinary typing (see
  `Scry2Web.Components.SearchBox`): the payload carries both `"key"` and
  `"value"`, and a dismiss must keep the typed text so the input and the
  applied filter cannot desync. `name_typed/3` and `card_typed/3` own that
  rule; callers pass the payload through untouched.
  """

  defstruct query: "", card: nil, card_query: "", name_suggestions: [], card_suggestions: []

  @type card :: %{key: String.t(), label: String.t()}
  @type candidate :: %{key: String.t(), label: String.t(), count: non_neg_integer()}

  @type t :: %__MODULE__{
          query: String.t(),
          card: card() | nil,
          card_query: String.t(),
          name_suggestions: [candidate()],
          card_suggestions: [candidate()]
        }

  defmodule Facets do
    @moduledoc """
    What one searchable deck exposes: the `names` it answers to (its own name,
    its archetype, its variants' names — nils allowed and ignored) and the
    `card_keys` it plays (`Scry2.DeckList.name_keys/2` output).
    """
    @enforce_keys [:names, :card_keys]
    defstruct [:names, :card_keys]

    @type t :: %__MODULE__{names: [String.t() | nil], card_keys: MapSet.t(String.t())}
  end

  @doc "An empty search — nothing typed, no card chosen, no suggestions open."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "True when the search narrows anything; drives 'no matches' empty states."
  @spec filtering?(t()) :: boolean()
  def filtering?(%__MODULE__{query: query, card: card}) do
    String.trim(query) != "" or not is_nil(card)
  end

  @doc "True when the deck satisfies both the text query and the chosen card."
  @spec match?(t(), Facets.t()) :: boolean()
  def match?(%__MODULE__{} = search, %Facets{} = facets) do
    match_text?(facets.names, search.query) and match_card?(facets.card_keys, search.card)
  end

  defp match_text?(_names, ""), do: true

  defp match_text?(names, query) do
    query_lower = String.downcase(query)
    Enum.any?(names, &contains?(&1, query_lower))
  end

  defp contains?(nil, _query_lower), do: false
  defp contains?(name, query_lower), do: String.contains?(String.downcase(name), query_lower)

  defp match_card?(_card_keys, nil), do: true
  defp match_card?(card_keys, %{key: key}), do: MapSet.member?(card_keys, key)

  @doc "Debounced keyup in the name box: apply the text, reopen its suggestions."
  @spec name_typed(t(), map(), [candidate()]) :: t()
  def name_typed(search, %{"key" => "Escape", "value" => value}, _candidates) do
    %{search | query: value, name_suggestions: []}
  end

  def name_typed(search, %{"value" => value}, candidates) do
    %{search | query: value, name_suggestions: rank_suggestions(candidates, value)}
  end

  @doc "A name suggestion was clicked: it becomes the query."
  @spec name_picked(t(), map()) :: t()
  def name_picked(search, %{"label" => label}) do
    %{search | query: label, name_suggestions: []}
  end

  @doc """
  Debounced keyup in the card box: rank its suggestions. The applied card
  filter only changes when a suggestion is picked, so typing never narrows
  the list on its own.
  """
  @spec card_typed(t(), map(), [candidate()]) :: t()
  def card_typed(search, %{"key" => "Escape", "value" => value}, _candidates) do
    %{search | card_query: value, card_suggestions: []}
  end

  def card_typed(search, %{"value" => value}, candidates) do
    %{search | card_query: value, card_suggestions: rank_suggestions(candidates, value)}
  end

  @doc "A card suggestion was clicked: it becomes the applied card filter."
  @spec card_picked(t(), map()) :: t()
  def card_picked(search, %{"key" => key, "label" => label}) do
    %{search | card: %{key: key, label: label}, card_query: "", card_suggestions: []}
  end

  @doc "The card filter chip was dismissed."
  @spec card_cleared(t()) :: t()
  def card_cleared(search), do: %{search | card: nil}

  @doc "Click-away: close both suggestion lists, keep what is applied."
  @spec dismissed(t()) :: t()
  def dismissed(search), do: %{search | name_suggestions: [], card_suggestions: []}

  @doc """
  Ranks candidates for a query: case-insensitive substring match, prefix
  matches first, then count descending, then label. Blank query yields
  nothing. Capped at `limit`.
  """
  @spec rank_suggestions([candidate()], String.t(), pos_integer()) :: [candidate()]
  def rank_suggestions(candidates, query, limit \\ 8) do
    normalized = query |> String.trim() |> String.downcase()

    if normalized == "" do
      []
    else
      candidates
      |> Enum.filter(fn candidate ->
        String.contains?(String.downcase(candidate.label), normalized)
      end)
      |> Enum.sort_by(fn candidate ->
        label = String.downcase(candidate.label)
        {if(String.starts_with?(label, normalized), do: 0, else: 1), -candidate.count, label}
      end)
      |> Enum.take(limit)
    end
  end

  @doc "Card suggestions from a `Scry2.DeckList.card_index/2` result."
  @spec card_candidates([%{key: String.t(), name: String.t(), count: pos_integer()}]) ::
          [candidate()]
  def card_candidates(card_index) do
    Enum.map(card_index, fn entry ->
      %{key: entry.key, label: entry.name, count: entry.count}
    end)
  end
end
