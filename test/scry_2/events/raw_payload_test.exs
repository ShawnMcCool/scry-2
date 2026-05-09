defmodule Scry2.Events.RawPayloadTest do
  use ExUnit.Case, async: true

  alias Scry2.Events.RawPayload

  describe "decode/1" do
    test "returns the same payload as Jason.decode/1 on first call" do
      record = %{id: 1, raw_json: ~s({"a":1,"b":[2,3]})}
      assert {:ok, %{"a" => 1, "b" => [2, 3]}} = RawPayload.decode(record)
    after
      RawPayload.forget(1)
    end

    test "second call with the same id returns cached payload without re-parsing" do
      record = %{id: 2, raw_json: ~s({"hello":"world"})}
      assert {:ok, payload} = RawPayload.decode(record)

      # Mutate raw_json — if cache is bypassed, decode would return the new
      # shape; with cache, original is returned.
      mutated = %{record | raw_json: ~s({"different":"value"})}
      assert {:ok, ^payload} = RawPayload.decode(mutated)
    after
      RawPayload.forget(2)
    end

    test "errors are not cached so retries can succeed" do
      bad = %{id: 3, raw_json: "not-json"}
      assert {:error, _} = RawPayload.decode(bad)

      good = %{id: 3, raw_json: ~s({"ok":true})}
      assert {:ok, %{"ok" => true}} = RawPayload.decode(good)
    after
      RawPayload.forget(3)
    end

    test "forget/1 evicts a cached entry" do
      record = %{id: 4, raw_json: ~s({"first":1})}
      assert {:ok, %{"first" => 1}} = RawPayload.decode(record)
      RawPayload.forget(4)

      mutated = %{record | raw_json: ~s({"second":2})}
      assert {:ok, %{"second" => 2}} = RawPayload.decode(mutated)
    after
      RawPayload.forget(4)
    end

    test "records without an id fall through to plain decode" do
      record = %{raw_json: ~s({"x":1})}
      assert {:ok, %{"x" => 1}} = RawPayload.decode(record)
    end
  end
end
