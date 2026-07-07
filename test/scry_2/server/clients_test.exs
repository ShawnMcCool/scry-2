defmodule Scry2.Server.ClientsTest do
  @moduledoc "Server-tier client token auth (ADR-042 Phase 2). Opt-in: docker compose up -d; SCRY2_SERVER_TESTS=1 MIX_ENV=test mix test.server"
  use Scry2.ServerCase, async: false

  @moduletag :server

  alias Scry2.Server.Client
  alias Scry2.Server.Clients
  alias Scry2.Server.User
  alias Scry2.ServerRepo

  defp create_user, do: ServerRepo.insert!(%User{})

  test "create!/2 issues a client with a token and returns both" do
    user = create_user()
    {client, token} = Clients.create!(user.id, label: "laptop")

    assert client.user_id == user.id
    assert client.label == "laptop"
    assert is_binary(token) and byte_size(token) > 20
  end

  test "authenticate/1 resolves a valid token to its user and client" do
    user = create_user()
    {client, token} = Clients.create!(user.id)

    assert {:ok, %{user_id: user_id, client_id: client_id}} = Clients.authenticate(token)
    assert user_id == user.id
    assert client_id == client.id
  end

  test "authenticate/1 returns :error for an unknown token" do
    create_user()
    assert :error = Clients.authenticate("not-a-real-token")
  end

  test "authenticate/1 returns :error for a non-binary token" do
    assert :error = Clients.authenticate(nil)
  end

  test "the raw token is never stored — only its hash" do
    user = create_user()
    {_client, token} = Clients.create!(user.id)

    stored = ServerRepo.one(Client)
    refute stored.token_hash == token
    assert String.length(stored.token_hash) == 64
  end
end
