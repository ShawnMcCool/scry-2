defmodule Scry2Web.SettingsLive.ReleaseNotesTest do
  @moduledoc """
  Pure tests for the markdown-lite parser that powers the
  "What's new" disclosure on the System page Updates card.

  Scope is deliberately narrow — we only render the shapes our own
  release notes produce (headings, bullets, bold, inline code).
  Anything outside that is passed through as plain text.
  """
  use ExUnit.Case, async: true

  alias Scry2Web.SettingsLive.ReleaseNotes

  describe "parse/1 — block shapes" do
    test "empty input parses to no blocks" do
      assert ReleaseNotes.parse("") == []
      assert ReleaseNotes.parse("   \n\n   ") == []
      assert ReleaseNotes.parse(nil) == []
    end

    test "a bare paragraph becomes a single :paragraph block" do
      assert [{:paragraph, [{:text, "Hello world."}]}] =
               ReleaseNotes.parse("Hello world.")
    end

    test "blank lines split blocks" do
      markdown = """
      First paragraph.

      Second paragraph.
      """

      assert [
               {:paragraph, [{:text, "First paragraph."}]},
               {:paragraph, [{:text, "Second paragraph."}]}
             ] = ReleaseNotes.parse(markdown)
    end

    test "headings of any level become :heading blocks" do
      assert [{:heading, 2, [{:text, "Fixed"}]}] = ReleaseNotes.parse("## Fixed")
      assert [{:heading, 3, [{:text, "New"}]}] = ReleaseNotes.parse("### New")
      assert [{:heading, 4, [{:text, "Deeper"}]}] = ReleaseNotes.parse("#### Deeper")
    end

    test "consecutive bullet lines merge into a single :list block" do
      markdown = """
      - first
      - second
      - third
      """

      assert [
               {:list,
                [
                  [{:text, "first"}],
                  [{:text, "second"}],
                  [{:text, "third"}]
                ]}
             ] = ReleaseNotes.parse(markdown)
    end

    test "bullet lines support a `*` marker as well as `-`" do
      assert [{:list, [[{:text, "alpha"}], [{:text, "beta"}]]}] =
               ReleaseNotes.parse("* alpha\n* beta")
    end

    test "bullet continuation on the next indented line joins the item" do
      markdown = """
      - One-line item.
      - Multi-line item that
        wraps across two source lines.
      """

      assert [{:list, items}] = ReleaseNotes.parse(markdown)
      assert length(items) == 2
      [_, second_inline] = items
      joined = Enum.map_join(second_inline, "", fn {:text, t} -> t end)
      assert joined =~ "Multi-line item"
      assert joined =~ "wraps across two source lines"
    end
  end

  describe "parse/1 — inline shapes" do
    test "bold runs are isolated" do
      assert [{:paragraph, inline}] = ReleaseNotes.parse("This is **bold** text.")

      assert inline == [
               {:text, "This is "},
               {:strong, [{:text, "bold"}]},
               {:text, " text."}
             ]
    end

    test "inline code is isolated" do
      assert [{:paragraph, inline}] = ReleaseNotes.parse("Run `mix test` now.")

      assert inline == [
               {:text, "Run "},
               {:code, "mix test"},
               {:text, " now."}
             ]
    end

    test "multiple inline spans in one paragraph are all extracted" do
      assert [{:paragraph, inline}] =
               ReleaseNotes.parse("Set **port** to `4444` in `config.toml`.")

      kinds = Enum.map(inline, &elem(&1, 0))
      assert :strong in kinds
      assert :code in kinds
      assert :text in kinds
    end

    test "unmatched asterisks or backticks fall through as literal text" do
      assert [{:paragraph, [{:text, "a*b c`d"}]}] = ReleaseNotes.parse("a*b c`d")
    end
  end

  describe "parse/1 — integration with a real release-notes shape" do
    test "parses a typical fix-and-feature release entry" do
      markdown = """
      ### Fixed

      - **Walker share KPI.** The reconciliation page now reflects
        actual walker hits via `Scry2.Collection.reader_path_breakdown/0`.
      - **Clippy.** Pre-existing `type_complexity` warnings cleared.

      ### Added

      - Release-notes disclosure on the Updates card.
      """

      blocks = ReleaseNotes.parse(markdown)
      kinds = Enum.map(blocks, &elem(&1, 0))

      assert :heading in kinds
      assert :list in kinds
    end
  end
end
