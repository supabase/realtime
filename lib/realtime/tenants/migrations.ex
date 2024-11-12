defmodule Realtime.Tenants.Migrations do
  @moduledoc """
  Run Realtime database migrations for tenant's database.
  """
  use GenServer

  require Logger

  import Realtime.Helpers, only: [log_error: 2]

  alias Realtime.Crypto
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
    MessagesUsingUuid
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
    {20_211_202_204_605,
     UpdateRealtimeBuildPreparedStatementSqlFunctionForCompatibilityWithAllTypes},
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
    {20_241_108_114_728, MessagesUsingUuid}
  ]

  @expected_migration_count length(@migrations)

  defstruct [:tenant_external_id, :settings]
  @spec run_migrations(map()) :: :ok | {:error, any()}
  def run_migrations(%__MODULE__{tenant_external_id: tenant_external_id} = attrs) do
    supervisor =
      {:via, PartitionSupervisor,
       {Realtime.Tenants.Migrations.DynamicSupervisor, tenant_external_id}}

    spec = {__MODULE__, attrs}

    case DynamicSupervisor.start_child(supervisor, spec) do
      :ignore -> :ok
      error -> error
    end
  end

  def start_link(%__MODULE__{tenant_external_id: tenant_external_id} = attrs) do
    name = {:via, Registry, {Unique, {__MODULE__, :host, tenant_external_id}}}
    GenServer.start_link(__MODULE__, attrs, name: name)
  end

  def init(%__MODULE__{tenant_external_id: tenant_external_id, settings: settings}) do
    Logger.metadata(external_id: tenant_external_id, project: tenant_external_id)

    case migrate(settings) do
      {:ok, _} -> :ignore
      {:error, error} -> {:stop, error}
    end
  end

  defp migrate(
         %{
           "db_host" => db_host,
           "db_port" => db_port,
           "db_name" => db_name,
           "db_user" => db_user,
           "db_password" => db_password
         } = settings
       ) do
    {host, port, name, user, pass} =
      Crypto.decrypt_creds(db_host, db_port, db_name, db_user, db_password)

    {:ok, addrtype} = Database.detect_ip_version(host)
    ssl_enforced = Database.default_ssl_param(settings)

    [
      hostname: host,
      port: port,
      database: name,
      password: pass,
      username: user,
      pool_size: 2,
      socket_options: [addrtype],
      parameters: [application_name: "realtime_migrations"],
      backoff_type: :stop
    ]
    |> Database.maybe_enforce_ssl_config(ssl_enforced)
    |> Repo.with_dynamic_repo(fn repo ->
      Logger.info("Applying migrations to #{host}")

      try do
        opts = [all: true, prefix: "realtime", dynamic_repo: repo]
        res = Ecto.Migrator.run(Repo, @migrations, :up, opts)

        {:ok, res}
      rescue
        error ->
          log_error("MigrationsFailedToRun", error)
          {:error, error}
      end
    end)
  end

  @doc """
  Checks if the number of migrations ran in the database is equal to the expected number of migrations.

  If not all migrations have been run, it will run the missing migrations.
  """
  @spec maybe_run_migrations(pid(), Tenant.t()) :: :ok
  def maybe_run_migrations(db_conn, tenant) do
    query =
      "select * from pg_catalog.pg_tables where schemaname = 'realtime' and tablename = 'schema_migrations';"

    %{extensions: [%{settings: settings} | _]} = tenant

    {:ok, %{num_rows: num_rows}} =
      Database.transaction(db_conn, fn db_conn -> Postgrex.query!(db_conn, query, []) end)

    if num_rows < @expected_migration_count do
      run_migrations(%__MODULE__{tenant_external_id: tenant.external_id, settings: settings})
    end

    :ok
  end

  @doc """
  Create partitions against tenant db connection
  """
  @spec create_partitions(pid()) :: :ok
  def create_partitions(db_conn_pid) do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    tomorrow = Date.add(today, 1)

    dates = [yesterday, today, tomorrow]

    Enum.each(dates, fn date ->
      partition_name = "messages_#{date |> Date.to_iso8601() |> String.replace("-", "_")}"
      start_timestamp = Date.to_string(date)
      end_timestamp = Date.to_string(Date.add(date, 1))

      Database.transaction(db_conn_pid, fn conn ->
        Postgrex.query(
          conn,
          """
          CREATE TABLE IF NOT EXISTS realtime.#{partition_name}
          PARTITION OF realtime.messages
          FOR VALUES FROM ('#{start_timestamp}') TO ('#{end_timestamp}');
          """,
          []
        )
      end)
    end)

    :ok
  end
end
