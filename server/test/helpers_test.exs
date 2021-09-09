defmodule Realtime.HelpersTest do
  use ExUnit.Case
  alias Realtime.Helpers

  test "env_kv_to_list/1 when env_val is valid" do
    def_h = [{"key3", "value3"}]
    env_valid = "key=value1:header2=value2"
    expect = {:ok, [{"key", "value1"}, {"header2", "value2"}, {"key3", "value3"}]}
    assert Helpers.env_kv_to_list(env_valid, def_h) === expect
  end

  test "env_kv_to_list/1 when env_val is not valid" do
    env_valid = "key=value1:header2value2"
    assert Helpers.env_kv_to_list(env_valid, []) === :error
  end

  test "env_kv_to_list/1 when env_val is emtpy" do
    assert Helpers.env_kv_to_list("", []) === :error
  end
end
