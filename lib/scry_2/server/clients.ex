defmodule Scry2.Server.Clients do
  @moduledoc """
  Issue and authenticate per-client bearer tokens (client/server split, ADR-042
  Phase 2). Tokens are random 256-bit secrets; only their SHA-256 hash is
  stored. `authenticate/1` maps an incoming token to `{:ok, %{user_id:, client_id:}}`
  for the ingest endpoint to stamp `user_id`, or `:error`.
  """
  import Ecto.Query

  alias Scry2.Server.Client
  alias Scry2.ServerRepo

  @doc "Creates a client for `user_id`, returning `{client, raw_token}`. The raw token is shown once."
  @spec create!(integer(), keyword()) :: {Client.t(), String.t()}
  def create!(user_id, opts \\ []) when is_integer(user_id) do
    token = generate_token()

    client =
      ServerRepo.insert!(%Client{
        user_id: user_id,
        token_hash: hash(token),
        label: Keyword.get(opts, :label)
      })

    {client, token}
  end

  @doc "Resolves a raw bearer token to `{:ok, %{user_id:, client_id:}}` or `:error`."
  @spec authenticate(term()) :: {:ok, %{user_id: integer(), client_id: integer()}} | :error
  def authenticate(token) when is_binary(token) do
    hashed = hash(token)

    query =
      from c in Client,
        where: c.token_hash == ^hashed,
        select: %{user_id: c.user_id, client_id: c.id}

    case ServerRepo.one(query) do
      nil -> :error
      context -> {:ok, context}
    end
  end

  def authenticate(_), do: :error

  defp generate_token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp hash(token), do: :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)
end
