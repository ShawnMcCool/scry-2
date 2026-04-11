defmodule Scry2.Health.ReportTest do
  use ExUnit.Case, async: true

  alias Scry2.Health.Check
  alias Scry2.Health.Report

  defp build_check(fields) do
    Check.new(
      Keyword.merge(
        [id: :sample, category: :processing, name: "Sample", status: :ok],
        fields
      )
    )
  end

  describe "new/1" do
    test "computes overall from the worst status present" do
      checks = [
        build_check(status: :ok),
        build_check(status: :warning),
        build_check(status: :ok)
      ]

      report = Report.new(checks)
      assert report.overall == :warning
      assert length(report.checks) == 3
      assert %DateTime{} = report.generated_at
    end

    test "empty check list resolves to :ok" do
      report = Report.new([])
      assert report.overall == :ok
      assert report.checks == []
    end
  end

  describe "worst_status/1" do
    test "returns :error when any check is :error" do
      checks = [
        build_check(status: :ok),
        build_check(status: :error),
        build_check(status: :warning)
      ]

      assert Report.worst_status(checks) == :error
    end

    test ":pending never outranks :ok" do
      checks = [build_check(status: :ok), build_check(status: :pending)]
      assert Report.worst_status(checks) == :ok
    end

    test ":pending alone resolves to :ok" do
      checks = [build_check(status: :pending)]
      assert Report.worst_status(checks) == :ok
    end

    test "empty list is :ok" do
      assert Report.worst_status([]) == :ok
    end
  end

  describe "by_category/1" do
    test "groups checks by category, preserving input order" do
      a = build_check(id: :a, category: :ingestion)
      b = build_check(id: :b, category: :card_data)
      c = build_check(id: :c, category: :ingestion)

      grouped = Report.by_category([a, b, c])
      assert grouped[:ingestion] == [a, c]
      assert grouped[:card_data] == [b]
    end

    test "accepts a %Report{}" do
      a = build_check(id: :a, category: :ingestion)
      report = Report.new([a])
      assert Report.by_category(report)[:ingestion] == [a]
    end
  end
end
