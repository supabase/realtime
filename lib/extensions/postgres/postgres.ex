defmodule Extensions.Postgres do
  @moduledoc false
  require Logger

  alias Extensions.Postgres
  alias Postgres.SubscriptionManager

  def start_distributed(scope, %{"region" => region} = params) do
    [fly_region | _] = Postgres.Regions.aws_to_fly(region)
    launch_node = launch_node(fly_region, node())

    Logger.warning(
      "Starting distributed postgres extension #{inspect(lauch_node: launch_node, region: region, fly_region: fly_region)}"
    )

    with :ok <- :rpc.call(launch_node, Postgres, :start, [scope, params]) do
      :ok
    else
      error_response ->
        Logger.error("Can't start postgres ext #{inspect(error_response, pretty: true)}")
        error_response
    end
  end

  @doc """
  Start db poller.

  """
  @spec start(String.t(), map()) ::
          :ok | {:error, :already_started}
  def start(scope, %{
        "db_host" => db_host,
        "db_name" => db_name,
        "db_user" => db_user,
        "db_password" => db_pass,
        "poll_interval_ms" => poll_interval_ms,
        "poll_max_changes" => poll_max_changes,
        "poll_max_record_bytes" => poll_max_record_bytes,
        "publication" => publication,
        "slot_name" => slot_name
      }) do
    :global.trans({{Extensions.Postgres, scope}, self()}, fn ->
      case :global.whereis_name({:supervisor, scope}) do
        :undefined ->
          opts = [
            id: scope,
            db_host: db_host,
            db_name: db_name,
            db_user: db_user,
            db_pass: db_pass,
            poll_interval_ms: poll_interval_ms,
            publication: publication,
            slot_name: slot_name,
            max_changes: poll_max_changes,
            max_record_bytes: poll_max_record_bytes
          ]

          Logger.info("Starting Extensions.Postgres, #{inspect(opts, pretty: true)}")

          {:ok, pid} =
            DynamicSupervisor.start_child(Postgres.DynamicSupervisor, %{
              id: scope,
              start: {Postgres.DynamicSupervisor, :start_link, [opts]},
              restart: :transient
            })

          case :global.register_name({:supervisor, scope}, pid) do
            :yes -> :ok
            :no -> {:error, :reserved}
          end

        _ ->
          {:error, :already_started}
      end
    end)
  end

  def subscribe(scope, subs_id, config, claims, channel_pid, postgres_extension) do
    pid =
      case manager_pid(scope) do
        nil ->
          start_distributed(scope, postgres_extension)
          manager_pid(scope)

        pid when is_pid(pid) ->
          pid
      end

    opts = %{
      config: config,
      id: subs_id,
      claims: claims,
      channel_pid: channel_pid
    }

    SubscriptionManager.subscribe(pid, opts)

    :global.whereis_name({:supervisor, scope})
    |> Process.monitor()
  end

  def unsubscribe(scope, subs_id) do
    pid = manager_pid(scope)

    if pid do
      SubscriptionManager.unsubscribe(pid, subs_id)
    end
  end

  def stop(scope) do
    case :global.whereis_name({:supervisor, scope}) do
      :undefined ->
        nil

      pid ->
        :global.whereis_name({:db_instance, scope})
        |> GenServer.stop(:normal)

        DynamicSupervisor.stop(pid, :shutdown)
    end
  end

  @spec manager_pid(any()) :: pid() | nil
  def manager_pid(scope) do
    case :global.whereis_name({:subscription_manager, scope}) do
      :undefined ->
        nil

      pid ->
        pid
    end
  end

  def launch_node(fly_region, default) do
    case :syn.members(Postgres.RegionNodes, fly_region) do
      [_ | _] = regions_nodes ->
        {_, [node: launch_node]} = Enum.random(regions_nodes)
        launch_node

      _ ->
        Logger.warning("Didn't find launch_node, return default #{inspect(default)}")
        default
    end
  end
end
