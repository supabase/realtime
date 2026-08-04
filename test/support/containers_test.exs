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

  describe "external_tenant_db_ports!/0" do
    test "parses a comma-separated EXTERNAL_TENANT_DB_PORTS list" do
      delete_env_restoring("EXTERNAL_TENANT_DB_PORT")
      put_env_restoring("EXTERNAL_TENANT_DB_PORTS", "15432, 15433,15434")
      assert Containers.external_tenant_db_ports!() == [15432, 15433, 15434]
    end

    test "falls back to singular EXTERNAL_TENANT_DB_PORT as a one-port list" do
      delete_env_restoring("EXTERNAL_TENANT_DB_PORTS")
      put_env_restoring("EXTERNAL_TENANT_DB_PORT", "15432")
      assert Containers.external_tenant_db_ports!() == [15432]
    end

    test "prefers EXTERNAL_TENANT_DB_PORTS when both are set" do
      put_env_restoring("EXTERNAL_TENANT_DB_PORTS", "15432,15433")
      put_env_restoring("EXTERNAL_TENANT_DB_PORT", "9999")
      assert Containers.external_tenant_db_ports!() == [15432, 15433]
    end

    test "raises a clear error when neither is set" do
      delete_env_restoring("EXTERNAL_TENANT_DB_PORTS")
      delete_env_restoring("EXTERNAL_TENANT_DB_PORT")

      assert_raise RuntimeError, ~r/EXTERNAL_TENANT_DB_PORTS/, fn ->
        Containers.external_tenant_db_ports!()
      end
    end
  end
end
