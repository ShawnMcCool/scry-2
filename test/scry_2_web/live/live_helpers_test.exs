defmodule Scry2Web.LiveHelpersTest do
  use ExUnit.Case, async: true

  alias Scry2Web.LiveHelpers, as: H

  describe "format_datetime/1" do
    test "returns — for nil" do
      assert H.format_datetime(nil) == "—"
    end

    test "formats a UTC datetime as YYYY-MM-DD HH:MM" do
      datetime = ~U[2026-04-05 07:09:00Z]
      assert H.format_datetime(datetime) == "2026-04-05 07:09"
    end
  end

  describe "format_label/1" do
    test "title-cases snake_case format strings" do
      assert H.format_label("premier_draft") == "Premier Draft"
      assert H.format_label("traditional_draft") == "Traditional Draft"
      assert H.format_label("sealed") == "Sealed"
    end

    test "returns — for nil" do
      assert H.format_label(nil) == "—"
    end
  end
end
