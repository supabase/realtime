defmodule ContainersTest do
  # These tests mutate the process-wide USE_EXTERNAL_TENANT_DB/
  # EXTERNAL_TENANT_DB_PORT(S) env vars that Containers.checkout/0,
  # storage_up!/1, and acquire_tenant_db/0 read at call time from any test in
  # the suite. Two consequences:
  #   - async: true would let those mutations race with concurrently running
  #     tenant-checkout tests elsewhere (e.g. skipping CREATE DATABASE, or an
  #     unrelated test raising ArgumentError mid-checkout) — hence async: false.
  #   - every mutation must restore the exact prior value on exit — not just
  #     delete it — or a later test file inherits the wrong mode for the rest
  #     of the run (see the put/delete_env_restoring helpers below).
  use ExUnit.Case, async: false

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

    test "falls back to EXTERNAL_TENANT_DB_PORT when EXTERNAL_TENANT_DB_PORTS is an empty string" do
      put_env_restoring("EXTERNAL_TENANT_DB_PORTS", "")
      put_env_restoring("EXTERNAL_TENANT_DB_PORT", "15432")
      assert Containers.external_tenant_db_ports!() == [15432]
    end

    test "raises the clear error when both are set but empty" do
      put_env_restoring("EXTERNAL_TENANT_DB_PORTS", "")
      put_env_restoring("EXTERNAL_TENANT_DB_PORT", "")

      assert_raise RuntimeError, ~r/EXTERNAL_TENANT_DB_PORTS/, fn ->
        Containers.external_tenant_db_ports!()
      end
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
