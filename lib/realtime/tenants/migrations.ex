defmodule Realtime.Tenants.Migrations do
  @moduledoc """
  Manage Tenant's database migrations.
  """

  use GenServer, restart: :transient
  use Realtime.Logs

  alias Realtime.Database
  alias Realtime.Registry.Unique
  alias Realtime.Repo
  alias Realtime.Api.Tenant
  alias Realtime.Api
  alias Realtime.Nodes
  alias Realtime.GenRpc
  alias Realtime.Telemetry

  @migrations [
    {20_211_116_024_918, __MODULE__.CreateRealtimeSubscriptionTable},
    {20_211_116_045_059, __MODULE__.CreateRealtimeCheckFiltersTrigger},
    {20_211_116_050_929, __MODULE__.CreateRealtimeQuoteWal2jsonFunction},
    {20_211_116_051_442, __MODULE__.CreateRealtimeCheckEqualityOpFunction},
    {20_211_116_212_300, __MODULE__.CreateRealtimeBuildPreparedStatementSqlFunction},
    {20_211_116_213_355, __MODULE__.CreateRealtimeCastFunction},
    {20_211_116_213_934, __MODULE__.CreateRealtimeIsVisibleThroughFiltersFunction},
    {20_211_116_214_523, __MODULE__.CreateRealtimeApplyRlsFunction},
    {20_211_122_062_447, __MODULE__.GrantRealtimeUsageToAuthenticatedRole},
    {20_211_124_070_109, __MODULE__.EnableRealtimeApplyRlsFunctionPostgrest9Compatibility},
    {20_211_202_204_204, __MODULE__.UpdateRealtimeSubscriptionCheckFiltersFunctionSecurity},
    {20_211_202_204_605, __MODULE__.UpdateRealtimeBuildPreparedStatementSqlFunctionForCompatibilityWithAllTypes},
    {20_211_210_212_804, __MODULE__.EnableGenericSubscriptionClaims},
    {20_211_228_014_915, __MODULE__.AddWalPayloadOnErrorsInApplyRlsFunction},
    {20_220_107_221_237, __MODULE__.UpdateChangeTimestampToIso8601ZuluFormat},
    {20_220_228_202_821, __MODULE__.UpdateSubscriptionCheckFiltersFunctionDynamicTableName},
    {20_220_312_004_840, __MODULE__.UpdateApplyRlsFunctionToApplyIso8601},
    {20_220_603_231_003, __MODULE__.AddQuotedRegtypesSupport},
    {20_220_603_232_444, __MODULE__.AddOutputForDataLessThanEqual64BytesWhenPayloadTooLarge},
    {20_220_615_214_548, __MODULE__.AddQuotedRegtypesBackwardCompatibilitySupport},
    {20_220_712_093_339, __MODULE__.RecreateRealtimeBuildPreparedStatementSqlFunction},
    {20_220_908_172_859, __MODULE__.NullPassesFiltersRecreateIsVisibleThroughFilters},
    {20_220_916_233_421, __MODULE__.UpdateApplyRlsFunctionToPassThroughDeleteEventsOnFilter},
    {20_230_119_133_233, __MODULE__.MillisecondPrecisionForWalrus},
    {20_230_128_025_114, __MODULE__.AddInOpToFilters},
    {20_230_128_025_212, __MODULE__.EnableFilteringOnDeleteRecord},
    {20_230_227_211_149, __MODULE__.UpdateSubscriptionCheckFiltersForInFilterNonTextTypes},
    {20_230_228_184_745, __MODULE__.ConvertCommitTimestampToUtc},
    {20_230_308_225_145, __MODULE__.OutputFullRecordWhenUnchangedToast},
    {20_230_328_144_023, __MODULE__.CreateListChangesFunction},
    {20_231_018_144_023, __MODULE__.CreateChannels},
    {20_231_204_144_023, __MODULE__.SetRequiredGrants},
    {20_231_204_144_024, __MODULE__.CreateRlsHelperFunctions},
    {20_231_204_144_025, __MODULE__.EnableChannelsRls},
    {20_240_108_234_812, __MODULE__.AddChannelsColumnForWriteCheck},
    {20_240_109_165_339, __MODULE__.AddUpdateGrantToChannels},
    {20_240_227_174_441, __MODULE__.AddBroadcastsPoliciesTable},
    {20_240_311_171_622, __MODULE__.AddInsertAndDeleteGrantToChannels},
    {20_240_321_100_241, __MODULE__.AddPresencesPoliciesTable},
    {20_240_401_105_812, __MODULE__.CreateRealtimeAdminAndMoveOwnership},
    {20_240_418_121_054, __MODULE__.RemoveCheckColumns},
    {20_240_523_004_032, __MODULE__.RedefineAuthorizationTables},
    {20_240_618_124_746, __MODULE__.FixWalrusRoleHandling},
    {20_240_801_235_015, __MODULE__.UnloggedMessagesTable},
    {20_240_805_133_720, __MODULE__.LoggedMessagesTable},
    {20_240_827_160_934, __MODULE__.FilterDeletePostgresChanges},
    {20_240_919_163_303, __MODULE__.AddPayloadToMessages},
    {20_240_919_163_305, __MODULE__.ChangeMessagesIdType},
    {20_241_019_105_805, __MODULE__.UuidAutoGeneration},
    {20_241_030_150_047, __MODULE__.MessagesPartitioning},
    {20_241_108_114_728, __MODULE__.MessagesUsingUuid},
    {20_241_121_104_152, __MODULE__.FixSendFunction},
    {20_241_130_184_212, __MODULE__.RecreateEntityIndexUsingBtree},
    {20_241_220_035_512, __MODULE__.FixSendFunctionPartitionCreation},
    {20_241_220_123_912, __MODULE__.RealtimeSendHandleExceptionsRemovePartitionCreation},
    {20_241_224_161_212, __MODULE__.RealtimeSendSetsConfig},
    {20_250_107_150_512, __MODULE__.RealtimeSubscriptionUnlogged},
    {20_250_110_162_412, __MODULE__.RealtimeSubscriptionLogged},
    {20_250_123_174_212, __MODULE__.RemoveUnusedPublications},
    {20_250_128_220_012, __MODULE__.RealtimeSendSetsTopicConfig},
    {20_250_506_224_012, __MODULE__.SubscriptionIndexBridgingDisabled},
    {20_250_523_164_012, __MODULE__.RunSubscriptionIndexBridgingDisabled},
    {20_250_714_121_412, __MODULE__.BroadcastSendErrorLogging},
    {20_250_905_041_441, __MODULE__.CreateMessagesReplayIndex},
    {20_251_103_001_201, __MODULE__.BroadcastSendIncludePayloadId},
    {20_251_120_212_548, __MODULE__.AddActionToSubscriptions},
    {20_251_120_215_549, __MODULE__.FilterActionPostgresChanges},
    {20_260_218_120_000, __MODULE__.FixByteaDoubleEncodingInCast},
    {20_260_326_120_000, __MODULE__.ListChangesWithSlotCount},
    {20_260_514_120_000, __MODULE__.AddBinaryPayloadToMessages},
    {20_260_527_120_000, __MODULE__.AddSelectColumnsToSubscriptions},
    {20_260_528_120_000, __MODULE__.Wal2jsonEscapeSpecialChars},
    {20_260_603_120_000, __MODULE__.AddSendBinaryFunction}
  ]

  defstruct [:tenant_external_id, :settings, migrations_ran: 0]

  @type t :: %__MODULE__{
          tenant_external_id: binary(),
          settings: map()
        }

  def migrations(), do: @migrations

  @doc """
  Checks if migrations for a given tenant need to run.
  """
  @spec run_migrations?(Tenant.t() | integer()) :: boolean()
  def run_migrations?(%Tenant{} = tenant), do: run_migrations?(tenant.migrations_ran)

  def run_migrations?(migrations_ran) when is_integer(migrations_ran),
    do: migrations_ran < Enum.count(@migrations)

  @doc """
  Run migrations for the given tenant, blocking until they complete.
  """
  @spec run_migrations(Tenant.t()) :: :ok | :noop | {:error, any()}
  def run_migrations(%Tenant{} = tenant) do
    if run_migrations?(tenant) do
      {node, attrs} = migration_target(tenant)
      GenRpc.call(node, __MODULE__, :start_migration, [attrs], tenant_id: tenant.external_id, timeout: 50_000)
    else
      :noop
    end
  end

  @doc """
  Triggers migrations for the given tenant without blocking the caller.
  """
  @spec run_migrations_async(Tenant.t()) :: :ok | :noop
  def run_migrations_async(%Tenant{} = tenant) do
    if run_migrations?(tenant) do
      {node, attrs} = migration_target(tenant)
      GenRpc.cast(node, __MODULE__, :start_migration, [attrs])
    else
      :noop
    end
  end

  defp migration_target(%Tenant{} = tenant) do
    %{extensions: [%{settings: settings} | _]} = tenant

    attrs = %__MODULE__{
      tenant_external_id: tenant.external_id,
      settings: settings,
      migrations_ran: tenant.migrations_ran
    }

    node =
      case Nodes.get_node_for_tenant(tenant) do
        {:ok, node, _} -> node
        {:error, _} -> node()
      end

    {node, attrs}
  end

  def start_migration(attrs) do
    supervisor =
      {:via, PartitionSupervisor, {Realtime.Tenants.Migrations.DynamicSupervisor, attrs.tenant_external_id}}

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

    case migrate(tenant_external_id, settings) do
      :ok ->
        Task.Supervisor.async_nolink(__MODULE__.TaskSupervisor, Api, :update_migrations_ran, [
          tenant_external_id,
          Enum.count(@migrations)
        ])

        :ignore

      {:error, error} ->
        {:stop, error}
    end
  end

  defp migrate(tenant_external_id, settings) do
    platform_region = Map.get(settings, "region")

    with {:ok, settings} <- Database.from_settings(settings, "realtime_migrations", :stop) do
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
        event = [:realtime, :tenants, :migrations]
        metadata = %{external_id: tenant_external_id, hostname: settings.hostname, platform_region: platform_region}
        start_time = Telemetry.start(event, metadata)

        try do
          opts = [all: true, prefix: "realtime", dynamic_repo: repo]
          result = Ecto.Migrator.run(Repo, @migrations, :up, opts)
          Telemetry.stop(event, start_time, Map.put(metadata, :migrations_executed, length(result)))
        rescue
          error ->
            metadata = Map.put(metadata, :error_code, error_code(error))

            Telemetry.exception(
              event,
              start_time,
              :error,
              error,
              __STACKTRACE__,
              metadata
            )

            {:error, error}
        end
      end)
    end
  end

  defp error_code(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp error_code(%DBConnection.ConnectionError{}), do: :connection_error
  defp error_code(_), do: :other
end
