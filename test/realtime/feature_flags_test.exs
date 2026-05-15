defmodule Realtime.FeatureFlagsTest do
  use Realtime.DataCase, async: false

  alias Realtime.Api
  alias Realtime.FeatureFlags
  alias Realtime.FeatureFlags.Cache
  alias Realtime.Tenants.Cache, as: TenantsCache

  setup do
    Cachex.clear(Cache)
    Cachex.clear(TenantsCache)
    :ok
  end

  describe "enabled?/1" do
    test "returns false when flag does not exist" do
      refute FeatureFlags.enabled?("missing_flag")
    end

    test "returns false when flag is disabled" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "off_flag", enabled: false})
      refute FeatureFlags.enabled?("off_flag")
    end

    test "returns true when flag is enabled" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "on_flag", enabled: true})
      assert FeatureFlags.enabled?("on_flag")
    end
  end

  describe "enabled?/2" do
    test "returns false when flag does not exist" do
      refute FeatureFlags.enabled?("missing_flag", "tenant_1")
    end

    test "returns false when flag is disabled and tenant has no entry (follows global)" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "off_flag", enabled: false})
      tenant = tenant_fixture(%{feature_flags: %{}})
      refute FeatureFlags.enabled?("off_flag", tenant.external_id)
    end

    test "returns true when flag is disabled globally but tenant has it explicitly enabled" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "tenant_override_flag", enabled: false})
      tenant = tenant_fixture(%{feature_flags: %{"tenant_override_flag" => true}})
      assert FeatureFlags.enabled?("tenant_override_flag", tenant.external_id)
    end

    test "returns global value when flag is enabled but tenant does not exist" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "enabled_flag", enabled: true})
      assert FeatureFlags.enabled?("enabled_flag", "nonexistent_tenant")
    end

    test "returns true when flag is enabled and tenant has no entry (follows global)" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "partial_flag", enabled: true})
      tenant = tenant_fixture(%{feature_flags: %{}})
      assert FeatureFlags.enabled?("partial_flag", tenant.external_id)
    end

    test "returns true when flag is enabled and tenant has it explicitly enabled" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "tenant_flag", enabled: true})
      tenant = tenant_fixture(%{feature_flags: %{"tenant_flag" => true}})
      assert FeatureFlags.enabled?("tenant_flag", tenant.external_id)
    end

    test "returns false when flag is enabled but tenant has it explicitly disabled" do
      {:ok, _} = Api.upsert_feature_flag(%{name: "disabled_for_tenant", enabled: true})
      tenant = tenant_fixture(%{feature_flags: %{"disabled_for_tenant" => false}})
      refute FeatureFlags.enabled?("disabled_for_tenant", tenant.external_id)
    end
  end
end
