defmodule Scry2.Server.IngestTest do
  @moduledoc """
  Server-tier ingest against real Postgres (client/server split, ADR-042 Phase 2).

  Opt-in: `docker compose up -d`, then
  `SCRY2_SERVER_TESTS=1 MIX_ENV=test mix test.server`.
  """
  use Scry2.ServerCase, async: false

  @moduletag :server

  alias Scry2.Events.EventRecord
  alias Scry2.Server.DomainEvent
  alias Scry2.Server.Ingest
  alias Scry2.Server.User
  alias Scry2.ServerRepo
  alias Scry2.Uplink.WireEvent

  # Builds a decoded wire event (WireEvent.decode shape) for a match_created,
  # keyed by mtga_source_id so the upload_key is stable across calls with the
  # same source.
  defp decoded_event(match_id, source_id) do
    %EventRecord{
      id: System.unique_integer([:positive]),
      event_type: "match_created",
      payload: %{"mtga_match_id" => match_id},
      mtga_source_id: source_id,
      mtga_timestamp: ~U[2026-06-01 12:00:00Z],
      sequence: 0,
      match_id: match_id
    }
    |> WireEvent.encode()
    |> WireEvent.decode()
  end

  defp create_user, do: ServerRepo.insert!(%User{})

  test "upserts a decoded wire batch and dedups re-uploads by (user_id, upload_key)" do
    user = create_user()
    batch = [decoded_event("m-1", 1001)]

    assert Ingest.ingest_batch(user.id, batch) == 1
    assert ServerRepo.aggregate(DomainEvent, :count) == 1

    # Re-uploading the same event upserts — no duplicate row.
    assert Ingest.ingest_batch(user.id, batch) == 1
    assert ServerRepo.aggregate(DomainEvent, :count) == 1
  end

  test "a changed payload for the same upload_key updates in place (retranslation)" do
    user = create_user()
    original = decoded_event("m-1", 1001)
    Ingest.ingest_batch(user.id, [original])

    corrected = %{original | payload: %{"mtga_match_id" => "m-1", "corrected" => true}}
    Ingest.ingest_batch(user.id, [corrected])

    row = ServerRepo.one(from d in DomainEvent, where: d.user_id == ^user.id)
    assert row.payload["corrected"] == true
    assert ServerRepo.aggregate(DomainEvent, :count) == 1
  end

  test "the same upload_key under different users is not deduped (attribution, not isolation)" do
    user_a = create_user()
    user_b = create_user()
    batch = [decoded_event("m-1", 1001)]

    Ingest.ingest_batch(user_a.id, batch)
    Ingest.ingest_batch(user_b.id, batch)

    assert ServerRepo.aggregate(DomainEvent, :count) == 2
  end

  test "stamps user_id and the domain fields onto the stored row" do
    user = create_user()
    Ingest.ingest_batch(user.id, [decoded_event("m-7", 7007)], client_id: 42)

    row = ServerRepo.one(DomainEvent)
    assert row.user_id == user.id
    assert row.client_id == 42
    assert row.event_type == "match_created"
    assert row.upload_key == "r:7007:match_created:0"
    assert row.match_id == "m-7"
    assert row.mtga_timestamp == ~U[2026-06-01 12:00:00Z]
  end

  test "an empty batch is a no-op" do
    user = create_user()
    assert Ingest.ingest_batch(user.id, []) == 0
    assert ServerRepo.aggregate(DomainEvent, :count) == 0
  end
end
