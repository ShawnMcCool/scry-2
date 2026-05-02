defmodule Scry2Web.Components.ForecastStrip.HelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.Components.ForecastStrip.Helpers

  describe "format_signed/1" do
    test "renders zero without a sign" do
      assert Helpers.format_signed(0) == "0"
      assert Helpers.format_signed(0.0) == "0"
    end

    test "renders positive integers with a leading +" do
      assert Helpers.format_signed(500) == "+500"
      assert Helpers.format_signed(12_345) == "+12,345"
    end

    test "renders negative integers with a Unicode minus" do
      assert Helpers.format_signed(-500) == "−500"
      assert Helpers.format_signed(-12_345) == "−12,345"
    end

    test "rounds floats to integers before formatting" do
      assert Helpers.format_signed(99.4) == "+99"
      assert Helpers.format_signed(-99.6) == "−100"
    end
  end

  describe "format_rate_suffix/1" do
    test "renders empty string for zero rate" do
      assert Helpers.format_rate_suffix(0.0) == ""
      assert Helpers.format_rate_suffix(0.4) == ""
    end

    test "renders + prefix for positive rates" do
      assert Helpers.format_rate_suffix(150.0) == " (+150/day)"
      assert Helpers.format_rate_suffix(1_500.0) == " (+1,500/day)"
    end

    test "renders Unicode minus for negative rates" do
      assert Helpers.format_rate_suffix(-150.0) == " (−150/day)"
    end
  end

  describe "vault_eta_label/1" do
    test "renders eta within 60 days as 'Vault opens <date> (in N days)'" do
      eta = ~U[2026-05-30 00:00:00Z]
      result = %{eta: eta, days: 28.0, rate_per_day: 2.0}
      assert Helpers.vault_eta_label(result) == "Vault opens May 30 (in 28 days)"
    end

    test "renders 'today' when ETA is within a day" do
      result = %{eta: ~U[2026-05-02 18:00:00Z], days: 0.5, rate_per_day: 50.0}
      assert Helpers.vault_eta_label(result) == "Vault opens today (May 2)"
    end

    test "renders 'tomorrow' when ETA is 1-1.5 days out" do
      result = %{eta: ~U[2026-05-03 06:00:00Z], days: 1.25, rate_per_day: 50.0}
      assert Helpers.vault_eta_label(result) == "Vault opens tomorrow (May 3)"
    end

    test "drops the parenthetical for far-future ETAs" do
      result = %{eta: ~U[2026-09-15 00:00:00Z], days: 136.0, rate_per_day: 0.4}
      assert Helpers.vault_eta_label(result) == "Vault opens Sep 15"
    end

    test "renders friendly text for non-numeric variants" do
      assert Helpers.vault_eta_label(:already_full) == "Vault full"
      assert Helpers.vault_eta_label(:no_progress) == "Vault not progressing"
      assert Helpers.vault_eta_label(:insufficient_data) == "Vault — not enough data"
    end
  end
end
