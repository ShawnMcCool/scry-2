defmodule Scry2.Collection.BuildChangeTest do
  use ExUnit.Case, async: true
  alias Scry2.Collection.BuildChange

  describe "detect/2" do
    test "no current build_hint → :no_data" do
      assert BuildChange.detect(nil, nil) == :no_data
      assert BuildChange.detect("BUILD-123", nil) == :no_data
    end

    test "no acknowledged but current present → :first_seen" do
      assert BuildChange.detect(nil, "BUILD-123") == :first_seen
    end

    test "acknowledged equals current → :current" do
      assert BuildChange.detect("BUILD-123", "BUILD-123") == :current
    end

    test "acknowledged differs from current → {:changed, prev, current}" do
      assert BuildChange.detect("BUILD-123", "BUILD-456") ==
               {:changed, "BUILD-123", "BUILD-456"}
    end
  end
end
