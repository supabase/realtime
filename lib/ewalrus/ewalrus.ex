defmodule Ewalrus do
  require Logger

  alias Ewalrus.SubscriptionManager
  @default_poll_interval 500

  @moduledoc """
  Documentation for `Ewalrus`.
  """

  def start_geo(aws_region, params) do
    [fly_region | _] = Ewalrus.Regions.aws_to_fly(aws_region)
    launch_node = launch_node(fly_region, node())

    Logger.debug(
      "Starting geo ewalrus #{inspect(lauch_node: launch_node, aws_region: aws_region, fly_region: fly_region)}"
    )

    :rpc.call(launch_node, Ewalrus, :start, [params])
  end

  def launch_node(fly_region, default) do
    case :syn.members(Ewalrus.RegionNodes, fly_region) do
      [{_, [node: launch_node]} | _] ->
        launch_node

      _ ->
        Logger.warning("Didn't find launch_node, return default #{inspect(default)}")
        default
    end
  end

  @doc """
  Start db poller.

  """
  @spec start(map()) ::
          :ok | {:error, :already_started}
  def start(%{
        scope: scope,
        host: host,
        db_name: db_name,
        db_user: db_user,
        db_pass: db_pass,
        poll_interval: poll_interval,
        publication: publication,
        slot_name: slot_name,
        max_changes: max_changes,
        max_record_bytes: max_record_bytes
      }) do
    :global.trans({{Ewalrus, scope}, self()}, fn ->
      case :global.whereis_name({:supervisor, scope}) do
        :undefined ->
          poll_interval =
            if !is_integer(poll_interval) do
              Logger.error("Wrong poll_interval value: #{inspect(poll_interval)}")
              @default_poll_interval
            else
              poll_interval
            end

          opts = [
            id: scope,
            db_host: host,
            db_name: db_name,
            db_user: db_user,
            db_pass: db_pass,
            poll_interval: poll_interval,
            publication: publication,
            slot_name: slot_name,
            max_changes: max_changes,
            max_record_bytes: max_record_bytes
          ]

          Logger.debug("Starting ewalrus, #{inspect(opts, pretty: true)}")

          {:ok, pid} =
            DynamicSupervisor.start_child(Ewalrus.RlsSupervisor, %{
              id: scope,
              start: {Ewalrus.DbSupervisor, :start_link, [opts]},
              restart: :transient
            })

          :global.register_name({:supervisor, scope}, pid)

        _ ->
          {:error, :already_started}
      end
    end)
  end

  def subscribe(scope, subs_id, topic, claims, transport_pid) do
    pid = manager_pid(scope)

    if pid do
      opts = %{
        topic: topic,
        id: subs_id,
        claims: claims
      }

      # TODO: move inside to SubscriptionManager
      bin_subs_id = UUID.string_to_binary!(subs_id)

      :syn.join(Ewalrus.Subscribers, scope, self(), %{
        bin_id: bin_subs_id,
        transport_pid: transport_pid
      })

      SubscriptionManager.subscribe(pid, opts)
    end
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
  defp manager_pid(scope) do
    case :global.whereis_name({:subscription_manager, scope}) do
      :undefined ->
        nil

      pid ->
        pid
    end
  end

  def dummy_params() do
    %{
      claims: %{
        "aud" => "authenticated",
        "email" => "jwt@test.com",
        "exp" => 1_663_819_211,
        "iat" => 1_632_283_191,
        "iss" => "supabase",
        "role" => "authenticated",
        "sub" => "bbb51e4e-f371-4463-bf0a-af8f56dc9a73"
      },
      id: UUID.uuid1(),
      topic: "public"
    }
  end
end
