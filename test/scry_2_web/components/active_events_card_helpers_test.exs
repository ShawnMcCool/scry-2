defmodule Scry2Web.Components.ActiveEventsCard.HelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.Components.ActiveEventsCard.Helpers, as: H

  defp record(overrides) do
    Map.merge(
      %{
        internal_event_name: "Premier_Draft_DFT",
        current_event_state: 1,
        current_module: 7,
        event_state: 0,
        format_type: 1,
        current_wins: 4,
        current_losses: 1,
        format_name: nil
      },
      Map.new(overrides)
    )
  end

  describe "display_name/1" do
    test "humanises CamelCase" do
      assert H.display_name(record(internal_event_name: "DualColorPrecons")) ==
               "Dual Color Precons"
    end

    test "strips trailing _YYYYMMDD" do
      assert H.display_name(record(internal_event_name: "PremierDraft_SOS_20260421")) ==
               "Premier Draft SOS"
    end

    test "splits snake_case" do
      assert H.display_name(record(internal_event_name: "Traditional_Alchemy_Event_2026")) ==
               "Traditional Alchemy Event 2026"
    end

    test "single-word names pass through" do
      assert H.display_name(record(internal_event_name: "Play")) == "Play"
    end

    test "nil → fallback" do
      assert H.display_name(record(internal_event_name: nil)) == "Unknown event"
    end

    test "empty string → fallback" do
      assert H.display_name(record(internal_event_name: "")) == "Unknown event"
    end
  end

  describe "record_label/1" do
    test "0-0 renders as em dash (don't show 0–0 for fresh entries)" do
      assert H.record_label(record(current_wins: 0, current_losses: 0)) == "—"
    end

    test "4-1 renders as 4–1 with en dash" do
      assert H.record_label(record(current_wins: 4, current_losses: 1)) == "4–1"
    end

    test "asymmetric losses-only renders" do
      assert H.record_label(record(current_wins: 0, current_losses: 2)) == "0–2"
    end
  end

  describe "format_label/1" do
    test "uses format_name when populated" do
      assert H.format_label(record(format_name: "Standard")) == "Standard"
    end

    test "humanises TraditionalStandard" do
      assert H.format_label(record(format_name: "TraditionalStandard")) ==
               "Traditional Standard"
    end

    test "falls back to format_type=1 → Limited when format_name nil" do
      assert H.format_label(record(format_name: nil, format_type: 1)) == "Limited"
    end

    test "falls back to format_type=3 → Constructed" do
      assert H.format_label(record(format_name: nil, format_type: 3)) == "Constructed"
    end

    test "unknown format → em dash" do
      assert H.format_label(record(format_name: nil, format_type: 0)) == "—"
    end
  end

  describe "state_label/1" do
    test "1 → In progress" do
      assert H.state_label(record(current_event_state: 1)) == "In progress"
    end

    test "3 → Standing" do
      assert H.state_label(record(current_event_state: 3)) == "Standing"
    end

    test "unexpected non-zero stays informative" do
      assert H.state_label(record(current_event_state: 99)) == "State 99"
    end
  end

  describe "state_badge_class/1" do
    test "1 → primary" do
      assert H.state_badge_class(record(current_event_state: 1)) == "badge-primary"
    end

    test "3 → info" do
      assert H.state_badge_class(record(current_event_state: 3)) == "badge-info"
    end

    test "unknown → ghost" do
      assert H.state_badge_class(record(current_event_state: 99)) == "badge-ghost"
    end
  end

  describe "entry_word/1" do
    test "1 → singular" do
      assert H.entry_word(1) == "entry"
    end

    test "0 → plural" do
      assert H.entry_word(0) == "entries"
    end

    test "many → plural" do
      assert H.entry_word(7) == "entries"
    end
  end

  describe "error_message/1" do
    test "MTGA not running has friendly copy" do
      assert H.error_message(:mtga_not_running) =~ "MTGA isn't running"
    end

    test "not_implemented mentions platform" do
      assert H.error_message(:not_implemented) =~ "platform"
    end

    test "unknown reason includes inspect output" do
      assert H.error_message({:weird, :error}) =~ "weird"
    end
  end
end
