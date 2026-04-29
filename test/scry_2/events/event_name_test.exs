defmodule Scry2.Events.EventNameTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.EventName

  describe "parse/1" do
    # ── Draft modes with set code and date ──────────────────────────────

    test "QuickDraft with set code and date" do
      result = EventName.parse("QuickDraft_FDN_20260323")

      assert result.format == "Quick Draft"
      assert result.format_type == "Limited"
      assert result.set_code == "FDN"
      assert result.wrapper == nil
      assert result.raw == "QuickDraft_FDN_20260323"
    end

    test "PremierDraft with set code and date" do
      result = EventName.parse("PremierDraft_LCI_20260401")

      assert result.format == "Premier Draft"
      assert result.format_type == "Limited"
      assert result.set_code == "LCI"
    end

    test "TradDraft with set code and date" do
      result = EventName.parse("TradDraft_FDN_20260501")

      assert result.format == "Traditional Draft"
      assert result.format_type == "Limited"
      assert result.set_code == "FDN"
    end

    test "CompDraft with set code and date" do
      result = EventName.parse("CompDraft_TMT_20260601")

      assert result.format == "Comp Draft"
      assert result.format_type == "Limited"
      assert result.set_code == "TMT"
    end

    test "BotDraft with set code and date" do
      result = EventName.parse("BotDraft_FDN_20260323")

      assert result.format == "Bot Draft"
      assert result.format_type == "Limited"
      assert result.set_code == "FDN"
    end

    test "Sealed with set code and date" do
      result = EventName.parse("Sealed_TMT_20260501")

      assert result.format == "Sealed"
      assert result.format_type == "Limited"
      assert result.set_code == "TMT"
    end

    test "PickTwoDraft with set code and date" do
      result = EventName.parse("PickTwoDraft_SOS_20260421")

      assert result.format == "Pick Two Draft"
      assert result.format_type == "Limited"
      assert result.set_code == "SOS"
    end

    # ── Wrapper events ──────────────────────────────────────────────────

    test "MWM wrapper with BotDraft" do
      result = EventName.parse("MWM_TMT_BotDraft_20260407")

      assert result.format == "Midweek Magic Bot Draft"
      assert result.format_type == "Limited"
      assert result.set_code == "TMT"
      assert result.wrapper == "Midweek Magic"
    end

    test "MWM wrapper with Sealed" do
      result = EventName.parse("MWM_FDN_Sealed_20260501")

      assert result.format == "Midweek Magic Sealed"
      assert result.format_type == "Limited"
      assert result.set_code == "FDN"
    end

    test "MWM wrapper with unknown mode" do
      result = EventName.parse("MWM_TMT_Singleton_20260501")

      assert result.format == "Midweek Magic Singleton"
      assert result.format_type == nil
      assert result.set_code == "TMT"
      assert result.wrapper == "Midweek Magic"
    end

    # ── Constructed modes ───────────────────────────────────────────────

    test "Ladder" do
      result = EventName.parse("Ladder")

      assert result.format == "Ranked"
      assert result.format_type == "Constructed"
      assert result.set_code == nil
    end

    test "Traditional_Ladder" do
      result = EventName.parse("Traditional_Ladder")

      assert result.format == "Ranked BO3"
      assert result.format_type == "Traditional"
      assert result.set_code == nil
    end

    test "Traditional_Play" do
      result = EventName.parse("Traditional_Play")

      assert result.format == "Play BO3"
      assert result.format_type == "Traditional"
    end

    test "Play" do
      result = EventName.parse("Play")

      assert result.format == "Play"
      assert result.format_type == "Constructed"
    end

    # ── Direct challenge ────────────────────────────────────────────────

    test "DirectGame" do
      result = EventName.parse("DirectGame")

      assert result.format == "Direct Challenge"
      assert result.format_type == "Constructed"
    end

    test "DirectGameLimited" do
      result = EventName.parse("DirectGameLimited")

      assert result.format == "Direct Challenge"
      assert result.format_type == "Limited"
    end

    # ── Special events ──────────────────────────────────────────────────

    test "Jump_In with year" do
      result = EventName.parse("Jump_In_2024")

      assert result.format == "Jump In!"
      assert result.format_type == "Limited"
    end

    test "DualColorPrecons" do
      result = EventName.parse("DualColorPrecons")

      assert result.format == "DualColorPrecons"
      assert result.format_type == nil
    end

    test "SparkyStarterDeckDuel" do
      result = EventName.parse("SparkyStarterDeckDuel")

      assert result.format == "SparkyStarterDeckDuel"
      assert result.format_type == nil
    end

    # ── Unknown with set code ───────────────────────────────────────────

    test "unknown mode with set code and date still extracts set" do
      result = EventName.parse("NewMode_ABC_20260901")

      assert result.set_code == "ABC"
    end

    # ── Nil input ───────────────────────────────────────────────────────

    test "nil returns nil fields" do
      result = EventName.parse(nil)

      assert result.format == nil
      assert result.format_type == nil
      assert result.set_code == nil
      assert result.wrapper == nil
    end
  end
end
