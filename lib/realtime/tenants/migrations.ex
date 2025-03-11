defmodule Realtime.Tenants.Migrations do
  @moduledoc """
  Run Realtime database migrations for tenant's database.
  """
  use GenServer, restart: :transient

  require Logger

  import Realtime.Logs

  alias Realtime.Database
  alias Realtime.Registry.Unique
  alias Realtime.Repo
  alias Realtime.Api.Tenant

  alias Realtime.Tenants.Migrations.{
    CreateRealtimeSubscriptionTable,
    CreateRealtimeCheckFiltersTrigger,
    CreateRealtimeQuoteWal2jsonFunction,
    CreateRealtimeCheckEqualityOpFunction,
    CreateRealtimeBuildPreparedStatementSqlFunction,
    CreateRealtimeCastFunction,
    CreateRealtimeIsVisibleThroughFiltersFunction,
    CreateRealtimeApplyRlsFunction,
    GrantRealtimeUsageToAuthenticatedRole,
    EnableRealtimeApplyRlsFunctionPostgrest9Compatibility,
    UpdateRealtimeSubscriptionCheckFiltersFunctionSecurity,
    UpdateRealtimeBuildPreparedStatementSqlFunctionForCompatibilityWithAllTypes,
    EnableGenericSubscriptionClaims,
    AddWalPayloadOnErrorsInApplyRlsFunction,
    UpdateChangeTimestampToIso8601ZuluFormat,
    UpdateSubscriptionCheckFiltersFunctionDynamicTableName,
    UpdateApplyRlsFunctionToApplyIso8601,
    AddQuotedRegtypesSupport,
    AddOutputForDataLessThanEqual64BytesWhenPayloadTooLarge,
    AddQuotedRegtypesBackwardCompatibilitySupport,
    RecreateRealtimeBuildPreparedStatementSqlFunction,
    NullPassesFiltersRecreateIsVisibleThroughFilters,
    UpdateApplyRlsFunctionToPassThroughDeleteEventsOnFilter,
    MillisecondPrecisionForWalrus,
    AddInOpToFilters,
    EnableFilteringOnDeleteRecord,
    UpdateSubscriptionCheckFiltersForInFilterNonTextTypes,
    ConvertCommitTimestampToUtc,
    OutputFullRecordWhenUnchangedToast,
    CreateListChangesFunction,
    CreateChannels,
    SetRequiredGrants,
    CreateRlsHelperFunctions,
    EnableChannelsRls,
    AddChannelsColumnForWriteCheck,
    AddUpdateGrantToChannels,
    AddBroadcastsPoliciesTable,
    AddInsertAndDeleteGrantToChannels,
    AddPresencesPoliciesTable,
    CreateRealtimeAdminAndMoveOwnership,
    RemoveCheckColumns,
    RedefineAuthorizationTables,
    FixWalrusRoleHandling,
    UnloggedMessagesTable,
    LoggedMessagesTable,
    FilterDeletePostgresChanges,
    AddPayloadToMessages,
    ChangeMessagesIdType,
    UuidAutoGeneration,
    MessagesPartitioning,
    MessagesUsingUuid,
    FixSendFunction,
    RecreateEntityIndexUsingBtree,
    FixSendFunctionPartitionCreation,
    RealtimeSendHandleExceptionsRemovePartitionCreation,
    RealtimeSendSetsConfig,
    RealtimeSubscriptionUnlogged,
    RealtimeSubscriptionLogged,
    RemoveUnusedPublications,
    RealtimeSendSetsTopicConfig
  }

  @migrations [
    {20_211_116_024_918, CreateRealtimeSubscriptionTable},
    {20_211_116_045_059, CreateRealtimeCheckFiltersTrigger},
    {20_211_116_050_929, CreateRealtimeQuoteWal2jsonFunction},
    {20_211_116_051_442, CreateRealtimeCheckEqualityOpFunction},
    {20_211_116_212_300, CreateRealtimeBuildPreparedStatementSqlFunction},
    {20_211_116_213_355, CreateRealtimeCastFunction},
    {20_211_116_213_934, CreateRealtimeIsVisibleThroughFiltersFunction},
    {20_211_116_214_523, CreateRealtimeApplyRlsFunction},
    {20_211_122_062_447, GrantRealtimeUsageToAuthenticatedRole},
    {20_211_124_070_109, EnableRealtimeApplyRlsFunctionPostgrest9Compatibility},
    {20_211_202_204_204, UpdateRealtimeSubscriptionCheckFiltersFunctionSecurity},
    {20_211_202_204_605, UpdateRealtimeBuildPreparedStatementSqlFunctionForCompatibilityWithAllTypes},
    {20_211_210_212_804, EnableGenericSubscriptionClaims},
    {20_211_228_014_915, AddWalPayloadOnErrorsInApplyRlsFunction},
    {20_220_107_221_237, UpdateChangeTimestampToIso8601ZuluFormat},
    {20_220_228_202_821, UpdateSubscriptionCheckFiltersFunctionDynamicTableName},
    {20_220_312_004_840, UpdateApplyRlsFunctionToApplyIso8601},
    {20_220_603_231_003, AddQuotedRegtypesSupport},
    {20_220_603_232_444, AddOutputForDataLessThanEqual64BytesWhenPayloadTooLarge},
    {20_220_615_214_548, AddQuotedRegtypesBackwardCompatibilitySupport},
    {20_220_712_093_339, RecreateRealtimeBuildPreparedStatementSqlFunction},
    {20_220_908_172_859, NullPassesFiltersRecreateIsVisibleThroughFilters},
    {20_220_916_233_421, UpdateApplyRlsFunctionToPassThroughDeleteEventsOnFilter},
    {20_230_119_133_233, MillisecondPrecisionForWalrus},
    {20_230_128_025_114, AddInOpToFilters},
    {20_230_128_025_212, EnableFilteringOnDeleteRecord},
    {20_230_227_211_149, UpdateSubscriptionCheckFiltersForInFilterNonTextTypes},
    {20_230_228_184_745, ConvertCommitTimestampToUtc},
    {20_230_308_225_145, OutputFullRecordWhenUnchangedToast},
    {20_230_328_144_023, CreateListChangesFunction},
    {20_231_018_144_023, CreateChannels},
    {20_231_204_144_023, SetRequiredGrants},
    {20_231_204_144_024, CreateRlsHelperFunctions},
    {20_231_204_144_025, EnableChannelsRls},
    {20_240_108_234_812, AddChannelsColumnForWriteCheck},
    {20_240_109_165_339, AddUpdateGrantToChannels},
    {20_240_227_174_441, AddBroadcastsPoliciesTable},
    {20_240_311_171_622, AddInsertAndDeleteGrantToChannels},
    {20_240_321_100_241, AddPresencesPoliciesTable},
    {20_240_401_105_812, CreateRealtimeAdminAndMoveOwnership},
    {20_240_418_121_054, RemoveCheckColumns},
    {20_240_523_004_032, RedefineAuthorizationTables},
    {20_240_618_124_746, FixWalrusRoleHandling},
    {20_240_801_235_015, UnloggedMessagesTable},
    {20_240_805_133_720, LoggedMessagesTable},
    {20_240_827_160_934, FilterDeletePostgresChanges},
    {20_240_919_163_303, AddPayloadToMessages},
    {20_240_919_163_305, ChangeMessagesIdType},
    {20_241_019_105_805, UuidAutoGeneration},
    {20_241_030_150_047, MessagesPartitioning},
    {20_241_108_114_728, MessagesUsingUuid},
    {20_241_121_104_152, FixSendFunction},
    {20_241_130_184_212, RecreateEntityIndexUsingBtree},
    {20_241_220_035_512, FixSendFunctionPartitionCreation},
    {20_241_220_123_912, RealtimeSendHandleExceptionsRemovePartitionCreation},
    {20_241_224_161_212, RealtimeSendSetsConfig},
    {20_250_107_150_512, RealtimeSubscriptionUnlogged},
    {20_250_110_162_412, RealtimeSubscriptionLogged},
    {20_250_123_174_212, RemoveUnusedPublications},
    {20_250_128_220_012, RealtimeSendSetsTopicConfig}
  ]

  defstruct [:tenant_external_id, :settings]

  @type t :: %__MODULE__{
          tenant_external_id: binary(),
          settings: map()
        }

  @doc """
  Run migrations for the given tenant.
  """
  @spec run_migrations(Tenant.t()) :: :ok | {:error, any()}
  def run_migrations(%Tenant{} = tenant) do
    %{extensions: [%{settings: settings} | _]} = tenant
    attrs = %__MODULE__{tenant_external_id: tenant.external_id, settings: settings}

    supervisor =
      {:via, PartitionSupervisor, {Realtime.Tenants.Migrations.DynamicSupervisor, tenant.external_id}}

    spec = {__MODULE__, attrs}

    Logger.info("Starting migration process for tenant: #{tenant.external_id}")
    case DynamicSupervisor.start_child(supervisor, spec) do
      :ignore ->
        Logger.info("Migration process for tenant #{tenant.external_id} already running, skipping")
        :ok
      {:ok, _pid} ->
        Logger.info("Migration process started for tenant #{tenant.external_id}")
        :ok
      {:error, error} ->
        Logger.error("Failed to start migration process for tenant #{tenant.external_id}: #{inspect(error)}")
        {:error, error}
    end
  end

  def start_link(%__MODULE__{tenant_external_id: tenant_external_id} = attrs) do
    name = {:via, Registry, {Unique, {__MODULE__, :host, tenant_external_id}}}
    Logger.info("Initializing migration GenServer for tenant: #{tenant_external_id}")
    GenServer.start_link(__MODULE__, attrs, name: name)
  end

  def init(%__MODULE__{tenant_external_id: tenant_external_id, settings: settings}) do
    Logger.metadata(external_id: tenant_external_id, project: tenant_external_id)
    Logger.info("Starting migration initialization for tenant: #{tenant_external_id}")

    case migrate(settings) do
      {:ok, result} ->
        Logger.info("Migration initialization completed successfully for tenant #{tenant_external_id}")
        {:ok, result}
      {:error, error} ->
        Logger.error("Migration initialization failed for tenant #{tenant_external_id}: #{inspect(error)}")
        {:stop, error}
    end
  end

  defp migrate(settings) do
    settings = Database.from_settings(settings, "realtime_migrations", :stop)

    # Apply fallback for hostname if it's "db"
    adjusted_hostname = if settings.hostname == "db" do
      Logger.warn("Hostname 'db' detected in migration, falling back to DB_HOST: #{System.get_env("DB_HOST")}")
      System.get_env("DB_HOST", "your-rds.ap-southeast-2.rds.amazonaws.com")
    else
      settings.hostname
    end

    Logger.info("Configuring database connection for migration: hostname=#{adjusted_hostname}, database=#{settings.database}, port=#{settings.port}")
    connection_config = [
      hostname: adjusted_hostname,
      port: settings.port,
      database: settings.database,
      password: settings.password,
      username: settings.username,
      pool_size: settings.pool_size,
      backoff_type: settings.backoff_type,
      socket_options: settings.socket_options,
      parameters: [application_name: settings.application_name, search_path: "realtime"],
      ssl: settings.ssl
    ]

    Repo.with_dynamic_repo(connection_config, fn repo ->
      Logger.info("Applying migrations with dynamic repo for tenant, schema: realtime")
      try do
        # Ensure the realtime schema exists (no need to stop conn manually)
        Postgrex.query!(Repo.get_dynamic_repo(), "CREATE SCHEMA IF NOT EXISTS realtime", [])

        opts = [all: true, prefix: "realtime", dynamic_repo: repo]
        Logger.info("Migration options: #{inspect(opts)}")
        total_count = 0
        failed_count = 0

        migrations = @migrations
        Logger.info("Found migrations: #{inspect(migrations)}")

        for {version, module} <- migrations do
          applied = Enum.any?(Ecto.Migrator.migrated_versions(repo), &(&1 == version))
          if applied do
            Logger.info("Migration #{version} (#{module}) already applied")
          else
            Logger.info("Applying migration: #{version} (#{module})")
            case Ecto.Migrator.up(repo, version, module) do
              :ok ->
                total_count = total_count + 1
                Logger.info("✅ Successfully applied migration: #{version} (#{module})")
              {:error, error} ->
                failed_count = failed_count + 1
                Logger.error("❌ Error applying migration #{version} (#{module}): #{inspect(error)}")
            end
          end
        end

        Logger.info("Migration process completed - Success: #{total_count}, Failed: #{failed_count}")
        {:ok, %{total: total_count, failed: failed_count}}
      rescue
        error ->
          log_error("MigrationsFailedToRun", error)
          Logger.error("Unexpected error during migration: #{inspect(error)}")
          {:error, error}
      end
    end)
  end

  @doc """
  Create partitions against tenant db connection
  """
  @spec create_partitions(pid()) :: :ok
  def create_partitions(db_conn_pid) do
    Logger.info("Starting partition creation for realtime.messages")
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    future = Date.add(today, 3)

    dates = Date.range(yesterday, future)

    Enum.each(dates, fn date ->
      partition_name = "messages_#{date |> Date.to_iso8601() |> String.replace("-", "_")}"
      start_timestamp = Date.to_string(date)
      end_timestamp = Date.to_string(Date.add(date, 1))

      Logger.info("Creating partition: #{partition_name}, range: #{start_timestamp} to #{end_timestamp}")
      case Database.transaction(db_conn_pid, fn conn ->
        query = """
        CREATE TABLE IF NOT EXISTS realtime.#{partition_name}
        PARTITION OF realtime.messages
        FOR VALUES FROM ('#{start_timestamp}') TO ('#{end_timestamp}');
        """

        Postgrex.query(conn, query, [])
      end) do
        {:ok, _} ->
          Logger.info("✅ Partition #{partition_name} created successfully")
        {:error, %Postgrex.Error{postgres: %{code: :duplicate_table}}} ->
          Logger.info("⚠ Partition #{partition_name} already exists, skipping")
        {:error, error} ->
          log_error("PartitionCreationFailed", error)
          Logger.error("❌ Failed to create partition #{partition_name}: #{inspect(error)}")
      end
    end)

    Logger.info("Partition creation process completed")
    :ok
  end
end
