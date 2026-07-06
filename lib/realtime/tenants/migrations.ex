defmodule Realtime.Tenants.Migrations do
  @moduledoc """
  Manage Tenant's database migrations.
  """

  use GenServer, restart: :transient
  use Realtime.Logs

  alias Realtime.Database
  alias Realtime.FeatureFlags
  alias Realtime.Registry.Unique
  alias Realtime.Repo
  alias Realtime.Api.Tenant
  alias Realtime.Api
  alias Realtime.Nodes
  alias Realtime.GenRpc
  alias Realtime.Telemetry

  alias Realtime.Tenants.Migrations

  @migrations [
    {20_211_116_024_918, Migrations.CreateRealtimeSubscriptionTable},
    {20_211_116_045_059, Migrations.CreateRealtimeCheckFiltersTrigger},
    {20_211_116_050_929, Migrations.CreateRealtimeQuoteWal2jsonFunction},
    {20_211_116_051_442, Migrations.CreateRealtimeCheckEqualityOpFunction},
    {20_211_116_212_300, Migrations.CreateRealtimeBuildPreparedStatementSqlFunction},
    {20_211_116_213_355, Migrations.CreateRealtimeCastFunction},
    {20_211_116_213_934, Migrations.CreateRealtimeIsVisibleThroughFiltersFunction},
    {20_211_116_214_523, Migrations.CreateRealtimeApplyRlsFunction},
    {20_211_122_062_447, Migrations.GrantRealtimeUsageToAuthenticatedRole},
    {20_211_124_070_109, Migrations.EnableRealtimeApplyRlsFunctionPostgrest9Compatibility},
    {20_211_202_204_204, Migrations.UpdateRealtimeSubscriptionCheckFiltersFunctionSecurity},
    {20_211_202_204_605, Migrations.UpdateRealtimeBuildPreparedStatementSqlFunctionForCompatibilityWithAllTypes},
    {20_211_210_212_804, Migrations.EnableGenericSubscriptionClaims},
    {20_211_228_014_915, Migrations.AddWalPayloadOnErrorsInApplyRlsFunction},
    {20_220_107_221_237, Migrations.UpdateChangeTimestampToIso8601ZuluFormat},
    {20_220_228_202_821, Migrations.UpdateSubscriptionCheckFiltersFunctionDynamicTableName},
    {20_220_312_004_840, Migrations.UpdateApplyRlsFunctionToApplyIso8601},
    {20_220_603_231_003, Migrations.AddQuotedRegtypesSupport},
    {20_220_603_232_444, Migrations.AddOutputForDataLessThanEqual64BytesWhenPayloadTooLarge},
    {20_220_615_214_548, Migrations.AddQuotedRegtypesBackwardCompatibilitySupport},
    {20_220_712_093_339, Migrations.RecreateRealtimeBuildPreparedStatementSqlFunction},
    {20_220_908_172_859, Migrations.NullPassesFiltersRecreateIsVisibleThroughFilters},
    {20_220_916_233_421, Migrations.UpdateApplyRlsFunctionToPassThroughDeleteEventsOnFilter},
    {20_230_119_133_233, Migrations.MillisecondPrecisionForWalrus},
    {20_230_128_025_114, Migrations.AddInOpToFilters},
    {20_230_128_025_212, Migrations.EnableFilteringOnDeleteRecord},
    {20_230_227_211_149, Migrations.UpdateSubscriptionCheckFiltersForInFilterNonTextTypes},
    {20_230_228_184_745, Migrations.ConvertCommitTimestampToUtc},
    {20_230_308_225_145, Migrations.OutputFullRecordWhenUnchangedToast},
    {20_230_328_144_023, Migrations.CreateListChangesFunction},
    {20_231_018_144_023, Migrations.CreateChannels},
    {20_231_204_144_023, Migrations.SetRequiredGrants},
    {20_231_204_144_024, Migrations.CreateRlsHelperFunctions},
    {20_231_204_144_025, Migrations.EnableChannelsRls},
    {20_240_108_234_812, Migrations.AddChannelsColumnForWriteCheck},
    {20_240_109_165_339, Migrations.AddUpdateGrantToChannels},
    {20_240_227_174_441, Migrations.AddBroadcastsPoliciesTable},
    {20_240_311_171_622, Migrations.AddInsertAndDeleteGrantToChannels},
    {20_240_321_100_241, Migrations.AddPresencesPoliciesTable},
    {20_240_401_105_812, Migrations.CreateRealtimeAdminAndMoveOwnership},
    {20_240_418_121_054, Migrations.RemoveCheckColumns},
    {20_240_523_004_032, Migrations.RedefineAuthorizationTables},
    {20_240_618_124_746, Migrations.FixWalrusRoleHandling},
    {20_240_801_235_015, Migrations.UnloggedMessagesTable},
    {20_240_805_133_720, Migrations.LoggedMessagesTable},
    {20_240_827_160_934, Migrations.FilterDeletePostgresChanges},
    {20_240_919_163_303, Migrations.AddPayloadToMessages},
    {20_240_919_163_305, Migrations.ChangeMessagesIdType},
    {20_241_019_105_805, Migrations.UuidAutoGeneration},
    {20_241_030_150_047, Migrations.MessagesPartitioning},
    {20_241_108_114_728, Migrations.MessagesUsingUuid},
    {20_241_121_104_152, Migrations.FixSendFunction},
    {20_241_130_184_212, Migrations.RecreateEntityIndexUsingBtree},
    {20_241_220_035_512, Migrations.FixSendFunctionPartitionCreation},
    {20_241_220_123_912, Migrations.RealtimeSendHandleExceptionsRemovePartitionCreation},
    {20_241_224_161_212, Migrations.RealtimeSendSetsConfig},
    {20_250_107_150_512, Migrations.RealtimeSubscriptionUnlogged},
    {20_250_110_162_412, Migrations.RealtimeSubscriptionLogged},
    {20_250_123_174_212, Migrations.RemoveUnusedPublications},
    {20_250_128_220_012, Migrations.RealtimeSendSetsTopicConfig},
    {20_250_506_224_012, Migrations.SubscriptionIndexBridgingDisabled},
    {20_250_523_164_012, Migrations.RunSubscriptionIndexBridgingDisabled},
    {20_250_714_121_412, Migrations.BroadcastSendErrorLogging},
    {20_250_905_041_441, Migrations.CreateMessagesReplayIndex},
    {20_251_103_001_201, Migrations.BroadcastSendIncludePayloadId},
    {20_251_120_212_548, Migrations.AddActionToSubscriptions},
    {20_251_120_215_549, Migrations.FilterActionPostgresChanges},
    {20_260_218_120_000, Migrations.FixByteaDoubleEncodingInCast},
    {20_260_326_120_000, Migrations.ListChangesWithSlotCount},
    {20_260_514_120_000, Migrations.AddBinaryPayloadToMessages},
    {20_260_527_120_000, Migrations.AddSelectColumnsToSubscriptions},
    {20_260_528_120_000, Migrations.Wal2jsonEscapeSpecialChars},
    {20_260_603_120_000, Migrations.AddSendBinaryFunction},
    {20_260_605_120_000, Migrations.RenameBroadcastSendWarning},
    {20_260_606_110_000, Migrations.SubscriptionCheckFiltersUsePgAttribute},
    {20_260_606_120_000, Migrations.SetupSupabaseRealtimeAdmin},
    {20_260_616_120_000, Migrations.AddPostgrestFilterOps},
    {20_260_624_120_000, Migrations.RevertPostgrestFilterOps},
    {20_260_626_120_000, Migrations.ReAddPostgrestFilterOps},
    {20_260_706_120_000, Migrations.GrantCheckEqualityOp5Arg}
  ]

  defstruct [:tenant_external_id, :settings, migrations_ran: 0]

  @type t :: %__MODULE__{
          tenant_external_id: binary(),
          settings: map()
        }

  @doc """
  Checks if migrations for a given tenant need to run.
  """
  @spec run_migrations?(Tenant.t() | integer()) :: boolean()
  def run_migrations?(%Tenant{} = tenant) do
    available_migrations =
      tenant.external_id
      |> migrations()
      |> Enum.count()

    tenant.migrations_ran < available_migrations
  end

  def run_migrations?(migrations_ran) when is_integer(migrations_ran),
    do: migrations_ran < Enum.count(migrations())

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
          Enum.count(migrations(tenant_external_id))
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
          result = Ecto.Migrator.run(Repo, migrations(tenant_external_id), :up, opts)
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

  @doc """
  Returns the migrations to run.
  """
  @spec migrations(String.t() | nil) :: [{pos_integer(), module()}]
  def migrations(tenant_external_id \\ nil) do
    Enum.filter(@migrations, fn {_version, module} -> migration_enabled?(module, tenant_external_id) end)
  end

  defp migration_enabled?(Migrations.SetupSupabaseRealtimeAdmin, nil = _tenant_external_id) do
    FeatureFlags.enabled?("use_supabase_realtime_admin")
  end

  defp migration_enabled?(Migrations.SetupSupabaseRealtimeAdmin, tenant_external_id)
       when is_binary(tenant_external_id) do
    FeatureFlags.enabled?("use_supabase_realtime_admin", tenant_external_id)
  end

  defp migration_enabled?(_migration, _tenant_external_id), do: true
end
