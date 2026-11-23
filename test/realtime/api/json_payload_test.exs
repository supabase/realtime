defmodule Realtime.Api.JsonPayloadTest do
  use ExUnit.Case, async: true

  alias Realtime.Api.JsonPayload

  @values [%{"a" => 1}, [1, 2, 3], "hello", 42, 1.5, true, false]

  test "type/0 returns :map" do
    assert JsonPayload.type() == :map
  end

  test "casts, loads and dumps any JSON value" do
    for value <- @values do
      assert JsonPayload.cast(value) == {:ok, value}
      assert JsonPayload.load(value) == {:ok, value}
      assert JsonPayload.dump(value) == {:ok, value}
    end
  end

  test "returns error for values that aren't JSON" do
    assert JsonPayload.cast({:a, 1}) == :error
    assert JsonPayload.dump(self()) == :error
  end
end
