defmodule Realtime.HelpersTest do
  use ExUnit.Case
  alias Realtime.Helpers

  test "env_kv_to_list/2 when env_val is valid" do
    def_h = [{"key3", "value3"}]
    env_valid = "key=value1:header2=value2"
    expect = {:ok, [{"header2", "value2"}, {"key", "value1"}, {"key3", "value3"}]}
    assert Helpers.env_kv_to_list(env_valid, def_h) === expect
  end

  test "env_kv_to_list/2 when env_val is not valid" do
    env_valid = "key=value1:header2value2"
    assert Helpers.env_kv_to_list(env_valid, []) === :error
  end

  test "env_kv_to_list/2 when env_val is emtpy" do
    assert Helpers.env_kv_to_list("", []) === :error
  end

  test "parse_kv/2 when string is valid and dafault is map" do
    expected = %{"key1" => "value1", "key2" => "value2", "key3" => "value3"}
    parsed = Helpers.parse_kv("key1=value1:key2=value2", %{"key3" => "value3"})
    assert Map.equal?(expected, parsed)
  end

  test "parse_kv/2 when dafault is not map" do
    fun = fn ->
      Helpers.parse_kv("key1=value1:key2=value2", [{"key3", "value3"}])
    end

    assert_raise(BadMapError, fun)
  end

  test "parse_kv/2 when string is empty" do
    assert Helpers.parse_kv("", %{}) === nil
  end

  test "parse_kv/2 when string is not valid" do
    assert Helpers.parse_kv("key1=value1:key2value2", %{}) === nil
    assert Helpers.parse_kv("key1value1", %{}) === nil
  end

  test "parse_kv/2 when '=' in value" do
    expected = %{"key1" => "value_with_=_symbol"}
    parsed = Helpers.parse_kv("key1=value_with_=_symbol", %{})
    assert Map.equal?(expected, parsed)
  end
end
