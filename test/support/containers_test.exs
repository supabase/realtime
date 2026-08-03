defmodule ContainersTest do
  use ExUnit.Case, async: true

  # These tests mutate process-wide env vars that the whole test run may
  # depend on (e.g. invoked with USE_EXTERNAL_TENANT_DB=true set globally), so
  # every mutation must restore the exact prior value on exit — not just
  # delete it — or a later test file inherits the wrong mode for the rest of
  # the run.
  defp put_env_restoring(name, value) do
    restore_env_on_exit(name)
    System.put_env(name, value)
  end

  defp delete_env_restoring(name) do
    restore_env_on_exit(name)
    System.delete_env(name)
  end

  defp restore_env_on_exit(name) do
    original = System.get_env(name)

    on_exit(fn ->
      if original, do: System.put_env(name, original), else: System.delete_env(name)
    end)
  end

  describe "external_tenant_db?/0" do
    test "false when USE_EXTERNAL_TENANT_DB is unset" do
      delete_env_restoring("USE_EXTERNAL_TENANT_DB")
      refute Containers.external_tenant_db?()
    end

    for value <- ["true", "TRUE", "1"] do
      test "true when USE_EXTERNAL_TENANT_DB=#{value}" do
        put_env_restoring("USE_EXTERNAL_TENANT_DB", unquote(value))
        assert Containers.external_tenant_db?()
      end
    end

    for value <- ["false", "FALSE", "0"] do
      test "false when USE_EXTERNAL_TENANT_DB=#{value}" do
        put_env_restoring("USE_EXTERNAL_TENANT_DB", unquote(value))
        refute Containers.external_tenant_db?()
      end
    end

    test "raises when USE_EXTERNAL_TENANT_DB is set to an unrecognized value" do
      put_env_restoring("USE_EXTERNAL_TENANT_DB", "yes")

      assert_raise ArgumentError, ~r/USE_EXTERNAL_TENANT_DB/, fn ->
        Containers.external_tenant_db?()
      end
    end
  end

  describe "external_tenant_db_port!/0" do
    test "returns the configured port as an integer" do
      put_env_restoring("EXTERNAL_TENANT_DB_PORT", "15432")
      assert Containers.external_tenant_db_port!() == 15432
    end

    test "raises a clear error when unset" do
      delete_env_restoring("EXTERNAL_TENANT_DB_PORT")

      assert_raise RuntimeError, ~r/EXTERNAL_TENANT_DB_PORT/, fn ->
        Containers.external_tenant_db_port!()
      end
    end
  end

  describe "handle_continue({:pool, _}, state) in external mode" do
    test "does not attempt to start a poolboy pool" do
      put_env_restoring("USE_EXTERNAL_TENANT_DB", "true")

      # Without the guard this raises a MatchError, because the real
      # Containers GenServer (started by test_helper.exs before this test
      # ran) has already registered Containers.Pool, and a second
      # :poolboy.start_link/2 with the same name fails to match {:ok, _pid}.
      assert {:noreply, %{}} = Containers.handle_continue({:pool, 4}, %{})
    end
  end
end
