defmodule Realtime.FeatureFlagsTest do
  use Realtime.DataCase, async: false

  alias Realtime.Api.FeatureFlag
  alias Realtime.FeatureFlags
  alias Realtime.FeatureFlags.Cache
  alias Realtime.Tenants.Cache, as: TenantsCache

  setup do
    Cachex.clear(Cache)
    Cachex.clear(TenantsCache)
    :ok
  end

  describe "list_flags/0" do
    test "returns all flags ordered by name" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "zebra_flag", enabled: false})
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "alpha_flag", enabled: true})

      assert FeatureFlags.list_flags() |> Enum.map(& &1.name) |> Enum.sort() == ["alpha_flag", "zebra_flag"]
    end
  end

  describe "get_flag/1" do
    test "returns the flag when it exists" do
      {:ok, flag} = FeatureFlags.upsert_flag(%{name: "my_flag", enabled: true})
      assert %FeatureFlag{name: "my_flag"} = FeatureFlags.get_flag("my_flag")
      assert FeatureFlags.get_flag("my_flag").id == flag.id
    end

    test "returns nil when flag does not exist" do
      refute FeatureFlags.get_flag("nonexistent")
    end
  end

  describe "upsert_flag/1" do
    test "inserts a new flag" do
      assert {:ok, %FeatureFlag{name: "new_flag", enabled: false}} =
               FeatureFlags.upsert_flag(%{name: "new_flag", enabled: false})
    end

    test "updates an existing flag" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "existing", enabled: false})

      assert {:ok, %FeatureFlag{name: "existing", enabled: true}} =
               FeatureFlags.upsert_flag(%{name: "existing", enabled: true})

      assert FeatureFlags.list_flags() |> Enum.count(&(&1.name == "existing")) == 1
    end

    test "returns error changeset when name is missing" do
      assert {:error, changeset} = FeatureFlags.upsert_flag(%{enabled: false})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "delete_flag/1" do
    test "removes the flag" do
      {:ok, flag} = FeatureFlags.upsert_flag(%{name: "to_delete", enabled: false})
      assert {:ok, _} = FeatureFlags.delete_flag(flag)
      refute FeatureFlags.get_flag("to_delete")
    end
  end

  describe "enabled?/1" do
    test "returns false when flag does not exist" do
      refute FeatureFlags.enabled?("missing_flag")
    end

    test "returns false when flag is disabled" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "off_flag", enabled: false})
      refute FeatureFlags.enabled?("off_flag")
    end

    test "returns true when flag is enabled" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "on_flag", enabled: true})
      assert FeatureFlags.enabled?("on_flag")
    end
  end

  describe "enabled?/2" do
    test "returns false when flag does not exist" do
      refute FeatureFlags.enabled?("missing_flag", "tenant_1")
    end

    test "returns false when flag is disabled and tenant has no entry (follows global)" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "off_flag", enabled: false})
      tenant = tenant_fixture(%{feature_flags: %{}})
      refute FeatureFlags.enabled?("off_flag", tenant.external_id)
    end

    test "returns true when flag is disabled globally but tenant has it explicitly enabled" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "tenant_override_flag", enabled: false})
      tenant = tenant_fixture(%{feature_flags: %{"tenant_override_flag" => true}})
      assert FeatureFlags.enabled?("tenant_override_flag", tenant.external_id)
    end

    test "returns global value when flag is enabled but tenant does not exist" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "enabled_flag", enabled: true})
      assert FeatureFlags.enabled?("enabled_flag", "nonexistent_tenant")
    end

    test "returns true when flag is enabled and tenant has no entry (follows global)" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "partial_flag", enabled: true})
      tenant = tenant_fixture(%{feature_flags: %{}})
      assert FeatureFlags.enabled?("partial_flag", tenant.external_id)
    end

    test "returns true when flag is enabled and tenant has it explicitly enabled" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "tenant_flag", enabled: true})
      tenant = tenant_fixture(%{feature_flags: %{"tenant_flag" => true}})
      assert FeatureFlags.enabled?("tenant_flag", tenant.external_id)
    end

    test "returns false when flag is enabled but tenant has it explicitly disabled" do
      {:ok, _} = FeatureFlags.upsert_flag(%{name: "disabled_for_tenant", enabled: true})
      tenant = tenant_fixture(%{feature_flags: %{"disabled_for_tenant" => false}})
      refute FeatureFlags.enabled?("disabled_for_tenant", tenant.external_id)
    end
  end
end
