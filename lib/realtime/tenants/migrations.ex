defmodule Realtime.Tenants.Migrations do
  @moduledoc """
  Run Realtime database migrations for tenant's database.
  """
  use GenServer, restart: :transient
  use Realtime.Logs

  alias Realtime.Tenants
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
    RealtimeSendSetsTopicConfig,
    SubscriptionIndexBridgingDisabled,
    RunSubscriptionIndexBridgingDisabled,
    BroadcastSendErrorLogging,
    CreateMessagesReplayIndex
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
    {20_250_128_220_012, RealtimeSendSetsTopicConfig},
    {20_250_506_224_012, SubscriptionIndexBridgingDisabled},
    {20_250_523_164_012, RunSubscriptionIndexBridgingDisabled},
    {20_250_714_121_412, BroadcastSendErrorLogging},
    {20_250_905_041_441, CreateMessagesReplayIndex}
  ]

  defstruct [:tenant_external_id, :settings]

  @type t :: %__MODULE__{
          tenant_external_id: binary(),
          settings: map()
        }

  @doc """
  Run migrations for the given tenant.
  """
  @spec run_migrations(Tenant.t()) :: :ok | :noop | {:error, any()}
  def run_migrations(%Tenant{} = tenant) do
    %{extensions: [%{settings: settings} | _]} = tenant
    attrs = %__MODULE__{tenant_external_id: tenant.external_id, settings: settings}

    supervisor =
      {:via, PartitionSupervisor, {Realtime.Tenants.Migrations.DynamicSupervisor, tenant.external_id}}

    spec = {__MODULE__, attrs}

    if Tenants.run_migrations?(tenant) do
      case DynamicSupervisor.start_child(supervisor, spec) do
        :ignore -> :ok
        error -> error
      end
    else
      :noop
    end
  end

  def start_link(%__MODULE__{tenant_external_id: tenant_external_id} = attrs) do
    name = {:via, Registry, {Unique, {__MODULE__, :host, tenant_external_id}}}
    GenServer.start_link(__MODULE__, attrs, name: name)
  end

  def init(%__MODULE__{tenant_external_id: tenant_external_id, settings: settings}) do
    Logger.metadata(external_id: tenant_external_id, project: tenant_external_id)

    case migrate(settings) do
      :ok ->
        Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, Tenants, :update_migrations_ran, [
          tenant_external_id,
          Enum.count(@migrations)
        ])

        :ignore

      {:error, error} ->
        {:stop, error}
    end
  end

  defp migrate(settings) do
    settings = Database.from_settings(settings, "realtime_migrations", :stop)

    [
      hostname: settings.hostname,
      port: settings.port,
      database: settings.database,
      password: settings.password,
      username: settings.username,
      pool_size: settings.pool_size,
      backoff_type: settings.backoff_type,
      socket_options: settings.socket_options,
      parameters: [application_name: settings.application_name],
      ssl: settings.ssl
    ]
    |> Repo.with_dynamic_repo(fn repo ->
      Logger.info("Applying migrations to #{settings.hostname}")

      try do
        opts = [all: true, prefix: "realtime", dynamic_repo: repo]
        Ecto.Migrator.run(Repo, @migrations, :up, opts)

        :ok
      rescue
        error ->
          log_error("MigrationsFailedToRun", error)
          {:error, error}
      end
    end)
  end

  @doc """
  Create partitions against tenant db connection
  """
  @spec create_partitions(pid()) :: :ok
  def create_partitions(db_conn_pid) do
    Logger.info("Creating partitions for realtime.messages")
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    future = Date.add(today, 3)

    dates = Date.range(yesterday, future)

    Enum.each(dates, fn date ->
      partition_name = "messages_#{date |> Date.to_iso8601() |> String.replace("-", "_")}"
      start_timestamp = Date.to_string(date)
      end_timestamp = Date.to_string(Date.add(date, 1))

      Database.transaction(db_conn_pid, fn conn ->
        query = """
        CREATE TABLE IF NOT EXISTS realtime.#{partition_name}
        PARTITION OF realtime.messages
        FOR VALUES FROM ('#{start_timestamp}') TO ('#{end_timestamp}');
        """

        case Postgrex.query(conn, query, []) do
          {:ok, _} -> Logger.debug("Partition #{partition_name} created")
          {:error, %Postgrex.Error{postgres: %{code: :duplicate_table}}} -> :ok
          {:error, error} -> log_error("PartitionCreationFailed", error)
        end
      end)
    end)

    :ok
  end

  def migrations(), do: @migrations
end
