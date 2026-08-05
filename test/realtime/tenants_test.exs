defmodule Realtime.TenantsTest do
  # async: false due to cache usage
  use Realtime.DataCase, async: false
  use Mimic

  setup :set_mimic_from_context

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database
  alias Realtime.FeatureFlags
  alias Realtime.GenCounter
  alias Realtime.Repo
  alias Realtime.Tenants
  doctest Realtime.Tenants

  describe "tenants" do
    test "get_tenant_limits/1" do
      tenant = tenant_fixture()
      keys = Tenants.limiter_keys(tenant)

      for key <- keys do
        GenCounter.add(key, 9)
      end

      limits = Tenants.get_tenant_limits(tenant, keys)

      [all] = Enum.filter(limits, fn e -> e.limiter == Tenants.requests_per_second_key(tenant) end)
      assert all.counter == 9

      [user_channels] = Enum.filter(limits, fn e -> e.limiter == Tenants.channels_per_client_key(tenant) end)
      assert user_channels.counter == 9

      [channel_joins] = Enum.filter(limits, fn e -> e.limiter == Tenants.joins_per_second_key(tenant) end)
      assert channel_joins.counter == 9

      [tenant_events] = Enum.filter(limits, fn e -> e.limiter == Tenants.events_per_second_key(tenant) end)
      assert tenant_events.counter == 9
    end
  end

  describe "region/1" do
    test "returns the region of the tenant" do
      attrs = %{
        "external_id" => random_string(),
        "name" => "tenant",
        "extensions" => [
          %{
            "type" => "postgres_cdc_rls",
            "settings" => %{
              "db_host" => "127.0.0.1",
              "db_name" => "postgres",
              "db_user" => "supabase_admin",
              "db_password" => "postgres",
              "db_port" => "#{port()}",
              "poll_interval" => 100,
              "poll_max_changes" => 100,
              "poll_max_record_bytes" => 1_048_576,
              "region" => "us-east-1",
              "publication" => "supabase_realtime_test",
              "ssl_enforced" => false
            }
          }
        ],
        "postgres_cdc_default" => "postgres_cdc_rls",
        "jwt_secret" => "new secret",
        "jwt_jwks" => nil
      }

      {:ok, tenant} = Realtime.Api.create_tenant(attrs)
      assert Tenants.region(tenant) == "us-east-1"
    end

    test "returns nil if no extension is set" do
      attrs = %{
        "external_id" => random_string(),
        "name" => "tenant",
        "extensions" => [],
        "postgres_cdc_default" => "postgres_cdc_rls",
        "jwt_secret" => "new secret",
        "jwt_jwks" => nil
      }

      {:ok, tenant} = Realtime.Api.create_tenant(attrs)
      assert Tenants.region(tenant) == nil
    end
  end

  describe "create_messages_partitions/1" do
    test "running twice keeps the same partitions" do
      tenant = TestTenantDb.checkout_tenant(run_migrations: true)
      {:ok, conn} = Database.connect(tenant, "realtime_test", :stop)

      assert :ok = Tenants.create_messages_partitions(conn)
      assert :ok = Tenants.create_messages_partitions(conn)

      assert {:ok, %{rows: [[5]]}} =
               Postgrex.query(
                 conn,
                 "SELECT count(*) FROM pg_inherits WHERE inhparent = 'realtime.messages'::regclass",
                 []
               )
    end
  end

  describe "reconcile_encryption/1" do
    setup do
      stub(FeatureFlags, :enabled?, fn "gcm_encryption_backfill", _tenant_id -> true end)
      :ok
    end

    test "does nothing when the gcm_encryption_backfill flag is disabled for the tenant" do
      tenant = Containers.checkout_tenant()
      tenant = simulate_pre_migration_state(tenant)
      stub(FeatureFlags, :enabled?, fn "gcm_encryption_backfill", _tenant_id -> false end)

      assert :ok = Tenants.reconcile_encryption(tenant)
      Process.sleep(200)

      reloaded = Api.get_tenant_by_external_id(tenant.external_id)
      assert is_nil(reloaded.jwt_secret_gcm)
      assert Enum.all?(reloaded.extensions, &is_nil(&1.settings_gcm))
    end

    test "backfills jwt_secret_gcm and each extension's settings_gcm without blocking the caller" do
      tenant = Containers.checkout_tenant()
      legacy_jwt_secret = tenant.jwt_secret
      [legacy_extension] = tenant.extensions
      legacy_db_password = legacy_extension.settings["db_password"]

      tenant = simulate_pre_migration_state(tenant)

      assert :ok = Tenants.reconcile_encryption(tenant)

      assert eventually(fn ->
               reloaded = Api.get_tenant_by_external_id(tenant.external_id)
               not is_nil(reloaded.jwt_secret_gcm) and Enum.all?(reloaded.extensions, & &1.settings_gcm)
             end)

      reloaded = Api.get_tenant_by_external_id(tenant.external_id)
      assert Crypto.decrypt_gcm!(reloaded.jwt_secret_gcm) == Crypto.decrypt!(legacy_jwt_secret)
      assert reloaded.jwt_secret == legacy_jwt_secret

      [reloaded_extension] = reloaded.extensions
      assert Crypto.decrypt_gcm!(reloaded_extension.settings_gcm["db_password"]) == Crypto.decrypt!(legacy_db_password)
      assert reloaded_extension.settings["db_password"] == legacy_db_password
    end

    test "does nothing for a tenant that already has jwt_secret_gcm and settings_gcm" do
      tenant = Containers.checkout_tenant()

      assert :ok = Tenants.reconcile_encryption(tenant)
      Process.sleep(200)

      reloaded = Api.get_tenant_by_external_id(tenant.external_id)
      assert reloaded.updated_at == tenant.updated_at
      assert Enum.map(reloaded.extensions, & &1.updated_at) == Enum.map(tenant.extensions, & &1.updated_at)
    end

    test "does nothing for a tenant authenticated via jwt_jwks only (no jwt_secret to migrate)" do
      tenant = Containers.checkout_tenant()
      tenant = simulate_pre_migration_state(tenant)
      tenant = %{tenant | jwt_secret: nil, jwt_secret_gcm: nil}

      assert :ok = Tenants.reconcile_encryption(tenant)
      Process.sleep(200)

      reloaded = Api.get_tenant_by_external_id(tenant.external_id)
      assert is_nil(reloaded.jwt_secret_gcm)
    end

    test "leaves a required field's ciphertext absent in settings_gcm when it was already missing from settings" do
      tenant = Containers.checkout_tenant()
      tenant = simulate_pre_migration_state(tenant)
      [extension] = tenant.extensions

      settings = Map.delete(extension.settings, "db_password")
      {:ok, extension} = extension |> Ecto.Changeset.change(%{settings: settings}) |> Repo.update()
      tenant = %{tenant | extensions: [extension]}

      assert :ok = Tenants.reconcile_encryption(tenant)

      assert eventually(fn ->
               reloaded = Api.get_tenant_by_external_id(tenant.external_id)
               Enum.all?(reloaded.extensions, & &1.settings_gcm)
             end)

      [reloaded_extension] = Api.get_tenant_by_external_id(tenant.external_id).extensions
      refute Map.has_key?(reloaded_extension.settings_gcm, "db_password")
    end

    test "logs telemetry and does not crash when the tenant has been deleted before the async write lands" do
      tenant = Containers.checkout_tenant()
      tenant = simulate_pre_migration_state(tenant)

      handler_id = {__MODULE__, self()}

      :telemetry.attach_many(
        handler_id,
        [[:realtime, :tenants, :encryption, :reconcile, :exception]],
        &__MODULE__.handle_telemetry/4,
        %{test_pid: self()}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert Api.delete_tenant_by_external_id(tenant.external_id)

      assert :ok = Tenants.reconcile_encryption(tenant)

      assert_receive {:telemetry_exception, %{reason: :tenant_not_found}}, 1000
      assert_receive {:telemetry_exception, %{reason: :extension_not_found}}, 1000
    end

    test "sets gcm_migrated_at once jwt_secret and every extension's settings are backfilled" do
      tenant = Containers.checkout_tenant()
      tenant = simulate_pre_migration_state(tenant)
      assert is_nil(tenant.gcm_migrated_at)

      assert :ok = Tenants.reconcile_encryption(tenant)

      assert eventually(fn ->
               reloaded = Api.get_tenant_by_external_id(tenant.external_id)
               not is_nil(reloaded.gcm_migrated_at)
             end)
    end

    test "leaves gcm_migrated_at unset when the tenant has been deleted before the async write lands" do
      tenant = Containers.checkout_tenant()
      tenant = simulate_pre_migration_state(tenant)

      assert Api.delete_tenant_by_external_id(tenant.external_id)

      assert :ok = Tenants.reconcile_encryption(tenant)
      Process.sleep(200)

      assert is_nil(Api.get_tenant_by_external_id(tenant.external_id))
    end
  end

  # Deliberately does not stub FeatureFlags: `enabled?/2` reads the tenant cache, and
  # `get_tenant_by_external_id/1` is the fallback Cachex runs for that key. Checking the flag from
  # inside the fallback re-enters the Cachex courier for an in-flight key and blocks on `:infinity`.
  describe "get_tenant_by_external_id/1 with the real feature flag lookup" do
    test "returns a legacy tenant through the cache while the backfill flag row exists" do
      tenant = Containers.checkout_tenant()
      external_id = tenant.external_id
      simulate_pre_migration_state(tenant)

      {:ok, _flag} = Api.upsert_feature_flag(%{name: "gcm_encryption_backfill", enabled: false})
      Tenants.Cache.invalidate_tenant_cache(external_id)

      task =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), self())
          Tenants.Cache.get_tenant_by_external_id(external_id)
        end)

      assert {:ok, %Tenant{external_id: ^external_id}} = Task.yield(task, 5_000),
             "get_tenant_by_external_id/1 deadlocked re-entering the tenant cache"
    end

    test "backfills the tenant when the flag is enabled for it" do
      tenant = Containers.checkout_tenant()
      external_id = tenant.external_id
      simulate_pre_migration_state(tenant)

      {:ok, _flag} = Api.upsert_feature_flag(%{name: "gcm_encryption_backfill", enabled: true})
      Tenants.Cache.invalidate_tenant_cache(external_id)

      assert %Tenant{} = Tenants.Cache.get_tenant_by_external_id(external_id)

      assert eventually(fn ->
               reloaded = Api.get_tenant_by_external_id(external_id)
               not is_nil(reloaded.jwt_secret_gcm) and Enum.all?(reloaded.extensions, & &1.settings_gcm)
             end)
    end
  end

  def handle_telemetry(_event, _measurements, metadata, %{test_pid: pid}),
    do: send(pid, {:telemetry_exception, metadata})

  defp simulate_pre_migration_state(tenant) do
    {:ok, tenant} = tenant |> Ecto.Changeset.change(%{jwt_secret_gcm: nil}) |> Repo.update()

    extensions =
      Enum.map(tenant.extensions, fn extension ->
        {:ok, extension} = extension |> Ecto.Changeset.change(%{settings_gcm: nil}) |> Repo.update()
        extension
      end)

    %{tenant | extensions: extensions}
  end
end
