defmodule Realtime.EnvTest do
  use ExUnit.Case, async: true

  alias Realtime.Env

  setup %{describe: describe, test: test_name} do
    env = "REALTIME_ENV_TEST_#{describe}_#{test_name}"
    on_exit(fn -> System.delete_env(env) end)
    %{env: env}
  end

  describe "get_integer/2" do
    test "returns the default when env is unset", %{env: env} do
      assert Env.get_integer(env, 10) == 10
    end

    test "returns nil when env is unset and no default is provided", %{env: env} do
      assert Env.get_integer(env) == nil
    end

    test "parses integer env values", %{env: env} do
      System.put_env(env, "42")
      assert Env.get_integer(env, 0) == 42
    end

    test "parses negative integer env values", %{env: env} do
      System.put_env(env, "-7")
      assert Env.get_integer(env, 0) == -7
    end

    test "raises on invalid integer env values", %{env: env} do
      System.put_env(env, "12ms")

      assert_raise ArgumentError, ~r/env #{env} expected a Integer, got "12ms"/, fn ->
        Env.get_integer(env, 0)
      end
    end

    test "raises when the default is not an integer or nil", %{env: env} do
      assert_raise ArgumentError,
                   ~r/expected either Integer or empty \(nil\) as default value for env #{env}, got "10"/,
                   fn ->
                     Env.get_integer(env, "10")
                   end
    end
  end

  describe "get_charlist/2" do
    test "returns the default when env is unset", %{env: env} do
      assert Env.get_charlist(env, ~c"abc") == ~c"abc"
    end

    test "returns env values as charlists", %{env: env} do
      System.put_env(env, "127.0.0.1")
      assert Env.get_charlist(env, ~c"0.0.0.0") == ~c"127.0.0.1"
    end

    test "returns an empty charlist when env is empty", %{env: env} do
      System.put_env(env, "")
      assert Env.get_charlist(env, ~c"fallback") == ~c""
    end

    test "raises when the default is not a charlist", %{env: env} do
      assert_raise ArgumentError,
                   ~r/expected a charlist as default value for env #{env}, got "abc"/,
                   fn ->
                     Env.get_charlist(env, "abc")
                   end
    end
  end

  describe "get_boolean/2" do
    test "returns the default when env is unset", %{env: env} do
      assert Env.get_boolean(env, true) == true
      assert Env.get_boolean(env, false) == false
    end

    test "parses truthy env values", %{env: env} do
      System.put_env(env, "true")
      assert Env.get_boolean(env, false) == true

      System.put_env(env, "1")
      assert Env.get_boolean(env, false) == true
    end

    test "parses falsy env values", %{env: env} do
      System.put_env(env, "false")
      assert Env.get_boolean(env, true) == false

      System.put_env(env, "0")
      assert Env.get_boolean(env, true) == false
    end

    test "normalizes whitespace and case before parsing", %{env: env} do
      System.put_env(env, " TRUE ")
      assert Env.get_boolean(env, false) == true

      System.put_env(env, " False ")
      assert Env.get_boolean(env, true) == false
    end

    test "raises on invalid boolean env values", %{env: env} do
      System.put_env(env, "yes")

      assert_raise ArgumentError, ~r/env #{env} expected a boolean or 0\/1 values, got "yes"/, fn ->
        Env.get_boolean(env, false)
      end
    end

    test "raises when the default is not a boolean", %{env: env} do
      assert_raise ArgumentError,
                   ~r/expected a boolean as default value for env #{env}, got "false"/,
                   fn ->
                     Env.get_boolean(env, "false")
                   end
    end
  end

  describe "get_binary/2" do
    test "returns the env value when present", %{env: env} do
      System.put_env(env, "configured")
      assert Env.get_binary(env, "default") == "configured"
    end

    test "returns the default binary when env is unset", %{env: env} do
      assert Env.get_binary(env, "default") == "default"
    end

    test "evaluates lazy defaults when env is unset", %{env: env} do
      assert Env.get_binary(env, fn -> "computed" end) == "computed"
    end

    test "does not evaluate lazy defaults when env is set", %{env: env} do
      System.put_env(env, "configured")
      assert Env.get_binary(env, fn -> flunk("default function should not be called") end) == "configured"
    end
  end

  describe "get_list/2" do
    test "returns the default when env is unset", %{env: env} do
      assert Env.get_list(env, ["a", "b"]) == ["a", "b"]
    end

    test "splits comma-separated env values", %{env: env} do
      System.put_env(env, "a,b,c")
      assert Env.get_list(env, []) == ["a", "b", "c"]
    end

    test "trims whitespace around list entries", %{env: env} do
      System.put_env(env, " a,  b ,c ")
      assert Env.get_list(env, []) == ["a", "b", "c"]
    end

    test "preserves empty entries when env is empty", %{env: env} do
      System.put_env(env, "")
      assert Env.get_list(env, ["fallback"]) == [""]
    end

    test "raises with a function clause when the default is not a list", %{env: env} do
      assert_raise FunctionClauseError, fn ->
        Env.get_list(env, "not-a-list")
      end
    end
  end
end
