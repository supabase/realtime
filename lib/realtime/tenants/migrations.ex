defmodule Realtime.Tenants.Migrations do
  @moduledoc """
  Run Realtime database migrations for tenant's database.
  """

  use GenServer, restart: :transient

  require Logger

  alias Realtime.Repo

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
    AddUpdateGrantToChannels
  }

  alias Realtime.Helpers, as: H

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
    {20_240_109_165_339, AddUpdateGrantToChannels}
  ]

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Callbacks

  @impl true
  def init(%{"id" => id} = args) do
    Logger.metadata(external_id: id, project: id)

    case apply_migrations(args) do
      {:ok, migrations} ->
        Logger.debug("Migrations applied successfully #{inspect(migrations)}")
        {:ok, %{}, {:continue, :stop}}

      {:error, error} ->
        runners = H.dirty_terminate_runners()
        Logger.error("Migrations failed, terminated runners: #{inspect(runners)}")
        {:stop, error}
    end
  end

  @impl true
  def handle_continue(:stop, %{}) do
    {:stop, :normal, %{}}
  end

  @spec apply_migrations(map()) :: {:ok, [integer()]} | {:error, any()}
  defp apply_migrations(
         %{
           "db_host" => db_host,
           "db_port" => db_port,
           "db_name" => db_name,
           "db_user" => db_user,
           "db_password" => db_password,
           "db_socket_opts" => db_socket_opts
         } = args
       ) do
    {host, port, name, user, pass} =
      H.decrypt_creds(
        db_host,
        db_port,
        db_name,
        db_user,
        db_password
      )

    ssl_enforced = H.default_ssl_param(args)

    [
      hostname: host,
      port: port,
      database: name,
      password: pass,
      username: user,
      pool_size: 2,
      socket_options: db_socket_opts,
      parameters: [
        application_name: "realtime_migrations"
      ],
      backoff_type: :stop
    ]
    |> H.maybe_enforce_ssl_config(ssl_enforced)
    |> Repo.with_dynamic_repo(fn repo ->
      Logger.info("Applying migrations to #{host}")

      try do
        res =
          Ecto.Migrator.run(
            Repo,
            @migrations,
            :up,
            all: true,
            prefix: "realtime",
            dynamic_repo: repo
          )

        {:ok, res}
      rescue
        error -> {:error, error}
      end
    end)
  end
end
