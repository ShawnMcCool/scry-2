defmodule Scry2.MtgaLogIngestion.GitHubIssueReportTest do
  use ExUnit.Case, async: true

  alias Scry2.MtgaLogIngestion.GitHubIssueReport, as: Report

  defp error_record(opts \\ []) do
    Map.merge(
      %{
        id: 1,
        event_type: "DraftMakeHumanDraftPick",
        occurred_at: ~U[2026-04-24 12:00:00Z],
        error_summary: "failed to decode payload: bad shape",
        raw_event: %{"some" => "payload"}
      },
      Map.new(opts)
    )
  end

  defp export(records, opts \\ []) do
    Map.merge(
      %{
        scry2_version: "0.16.0",
        exported_at: ~U[2026-04-24 12:00:00Z],
        error_count: length(records),
        errors: records
      },
      Map.new(opts)
    )
  end

  describe "categorize/1" do
    test "decode_failure when message contains 'failed to decode'" do
      assert Report.categorize("failed to decode payload: foo") == :decode_failure
    end

    test "missing_field on key/enforce_keys/missing required" do
      assert Report.categorize("** key :gameStateId not found") == :missing_field
      assert Report.categorize("enforce_keys violated") == :missing_field
      assert Report.categorize("missing required field x") == :missing_field
    end

    test "generic when no marker matches" do
      assert Report.categorize("some other unrelated error") == :generic
    end

    test "unknown when nil" do
      assert Report.categorize(nil) == :unknown
    end
  end

  describe "build/2 — title is deterministic across users" do
    test "single signature: title names event_type and category" do
      records = [
        error_record(error_summary: "failed to decode foo"),
        error_record(id: 2, error_summary: "failed to decode foo")
      ]

      result = Report.build(export(records))

      assert result.title ==
               "[ingestion error] DraftMakeHumanDraftPick — failed to decode payload"
    end

    test "two distinct signatures: dominant signature + (+1 other type)" do
      records = [
        error_record(error_summary: "failed to decode foo"),
        error_record(id: 2, error_summary: "failed to decode foo"),
        error_record(
          id: 3,
          event_type: "GreToClientEvent",
          error_summary: "key :gameStateId not found"
        )
      ]

      result = Report.build(export(records))

      assert String.starts_with?(
               result.title,
               "[ingestion error] DraftMakeHumanDraftPick — failed to decode payload"
             )

      assert String.ends_with?(result.title, "(+1 other type)")
    end

    test "three+ signatures: '+N other types'" do
      records = [
        error_record(),
        error_record(id: 2, event_type: "A", error_summary: "key :x not found"),
        error_record(id: 3, event_type: "B", error_summary: "weird thing"),
        error_record(id: 4, event_type: "C", error_summary: "another weird thing")
      ]

      result = Report.build(export(records))

      assert String.contains?(result.title, "(+3 other types)") or
               String.contains?(result.title, "(+2 other types)")
    end

    test "two users with the same broken event get the same title" do
      user_a_records = [
        error_record(id: 100, occurred_at: ~U[2026-04-24 12:00:00Z]),
        error_record(id: 101, occurred_at: ~U[2026-04-24 12:01:00Z])
      ]

      user_b_records = [
        error_record(id: 9000, occurred_at: ~U[2026-05-01 03:00:00Z])
      ]

      result_a = Report.build(export(user_a_records))
      result_b = Report.build(export(user_b_records))

      assert result_a.title == result_b.title,
             "title must depend only on (event_type, category), not IDs/timestamps"
    end

    test "empty errors produces a stable fallback title" do
      result = Report.build(export([]))
      assert is_binary(result.title)
      assert String.contains?(result.title, "ingestion error")
    end
  end

  describe "build/2 — body" do
    test "includes Scry2 version, platform, and total count" do
      result = Report.build(export([error_record()]), platform: "fake-platform")

      assert result.body =~ "Scry2 version"
      assert result.body =~ "0.16.0"
      assert result.body =~ "fake-platform"
      assert result.body =~ "Total errors in batch:** 1"
    end

    test "includes a markdown signature summary table" do
      records = [
        error_record(),
        error_record(id: 2),
        error_record(id: 3, event_type: "Other", error_summary: "key :x")
      ]

      result = Report.build(export(records))

      assert result.body =~ "| Event type | Category | Count |"
      assert result.body =~ "DraftMakeHumanDraftPick"
      assert result.body =~ "Other"
    end

    test "includes a fenced JSON sample for each signature" do
      result = Report.build(export([error_record(raw_event: %{"k" => "v"})]))

      assert result.body =~ "```json"
      assert result.body =~ ~s("k": "v")
    end

    test "caps individual payload size with a (truncated) marker" do
      huge = Map.new(1..500, fn i -> {"key#{i}", String.duplicate("x", 50)} end)
      result = Report.build(export([error_record(raw_event: huge)]))

      assert result.body =~ "(truncated)"
    end
  end

  describe "build/2 — url" do
    test "url is the issue endpoint with title and body encoded" do
      result = Report.build(export([error_record()]))

      assert String.starts_with?(
               result.url,
               "https://github.com/shawnmccool/scry_2/issues/new?"
             )

      assert result.url =~ "title="
      assert result.url =~ "body="
      assert result.url =~ "labels=ingestion-error"
    end

    test "url-encoded title round-trips back to the title" do
      result = Report.build(export([error_record()]))
      query = URI.parse(result.url).query
      assert URI.decode_query(query)["title"] == result.title
    end

    test "url-encoded body round-trips back to the body" do
      result = Report.build(export([error_record()]))
      query = URI.parse(result.url).query
      assert URI.decode_query(query)["body"] == result.body
    end
  end

  describe "build/2 — signatures field" do
    test "returns one entry per distinct (event_type, category) pair" do
      records = [
        error_record(),
        error_record(id: 2),
        error_record(id: 3, event_type: "Other", error_summary: "key :x not found"),
        error_record(id: 4, event_type: "Other", error_summary: "key :x not found"),
        error_record(id: 5, event_type: "Other", error_summary: "key :x not found")
      ]

      result = Report.build(export(records))

      assert length(result.signatures) == 2

      # Sorted by count descending — Other (3) comes before
      # DraftMakeHumanDraftPick (2).
      [first, second] = result.signatures
      assert first.signature == {"Other", :missing_field}
      assert first.count == 3
      assert second.signature == {"DraftMakeHumanDraftPick", :decode_failure}
      assert second.count == 2
    end
  end
end
