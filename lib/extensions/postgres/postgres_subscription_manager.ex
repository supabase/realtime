defmodule Extensions.Postgres.SubscriptionManager do
  @moduledoc """
  Handles subscriptions from multiple databases.
  """
  use GenServer
  require Logger

  alias Extensions.Postgres
  alias Postgres.Subscriptions
  alias RealtimeWeb.{UserSocket, Endpoint}

  import Realtime.Helpers, only: [cancel_timer: 1]

  @check_oids_interval 60_000
  @queue_target 5_000
  @pool_size 5
  @timeout 15_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(%{args: args, subscribers_tid: subscribers_tid}) do
    id = Keyword.fetch!(args, :id)

    state = %{
      check_active_pids: nil,
      check_oid_ref: nil,
      conn: nil,
      db_host: Keyword.fetch!(args, :db_host),
      db_name: Keyword.fetch!(args, :db_name),
      db_pass: Keyword.fetch!(args, :db_pass),
      db_user: Keyword.fetch!(args, :db_user),
      id: id,
      oids: %{},
      subscribers_tid: subscribers_tid,
      publication: Keyword.fetch!(args, :publication)
    }

    {:ok, state, {:continue, :database_manager_setup}}
  end

  @impl true
  def handle_continue(
        :database_manager_setup,
        %{
          db_host: db_host,
          db_name: db_name,
          db_pass: db_pass,
          db_user: db_user,
          id: id
        } = state
      ) do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: db_host,
        database: db_name,
        password: db_pass,
        username: db_user,
        pool_size: @pool_size,
        queue_target: @queue_target
      )

    {:ok, _} = Subscriptions.maybe_delete_all(conn)

    :yes = :global.register_name({:tenant_db, :replication, :manager, id}, self())

    send(self(), :check_oids)

    {:noreply, %{state | conn: conn}}
  end

  @spec subscribe(pid, map) :: {:ok, nil} | {:error, any()}
  def subscribe(pid, opts) do
    GenServer.call(pid, {:subscribe, opts}, @timeout)
  end

  def subscribers_list(pid) do
    GenServer.call(pid, :subscribers_list)
  end

  @spec unsubscribe(atom | pid | port | reference | {atom, atom}, any) :: any
  def unsubscribe(pid, subs_id) do
    send(pid, {:unsubscribe, subs_id})
  end

  @spec disconnect_subscribers(pid) :: :ok
  def disconnect_subscribers(pid) do
    GenServer.call(pid, :disconnect_subscribers, @timeout)
  end

  @impl true
  def handle_call(
        {:subscribe, %{channel_pid: pid, claims: claims, config: config, id: id} = opts},
        _,
        %{check_active_pids: ref, publication: publication, subscribers_tid: tid} = state
      ) do
    Logger.debug("Subscribe #{inspect(opts, pretty: true)}")

    subscription_opts = %{
      id: id,
      config: config,
      claims: claims
    }

    monitor_ref = Process.monitor(pid)
    true = :ets.insert(tid, {pid, id, config, claims, monitor_ref})

    create_resp = Subscriptions.create(state.conn, publication, subscription_opts)

    new_state =
      if ref == nil do
        %{state | check_active_pids: check_active_pids()}
      else
        state
      end

    {:reply, create_resp, new_state}
  end

  def handle_call(:disconnect_subscribers, _, state) do
    %{id: id, conn: conn, subscribers_tid: tid} = state

    fn {_, _, _, _, ref}, _acc ->
      Process.demonitor(ref, [:flush])
    end
    |> :ets.foldl([], tid)

    UserSocket.subscribers_id(id)
    |> Endpoint.broadcast("disconnect", %{})

    :ets.delete_all_objects(tid)
    Subscriptions.delete_all(conn)

    {:reply, :ok, state}
  end

  def handle_call(:subscribers_list, _, state) do
    subscribers =
      :ets.foldl(
        fn {pid, _, _, _, _}, acc ->
          [pid | acc]
        end,
        [],
        state.subscribers_tid
      )

    {:reply, subscribers, state}
  end

  @impl true
  def handle_info(
        :check_oids,
        %{check_oid_ref: ref, conn: conn, publication: publication, oids: old_oids} = state
      ) do
    cancel_timer(ref)

    oids =
      case Subscriptions.fetch_publication_tables(conn, publication) do
        ^old_oids ->
          old_oids

        new_oids ->
          Logger.warning("Found new oids #{inspect(new_oids, pretty: true)}")
          Subscriptions.update_all(conn, state.subscribers_tid, publication)
          new_oids
      end

    {:noreply, %{state | oids: oids, check_oid_ref: check_oids()}}
  end

  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{subscribers_tid: tid} = state) do
    case :ets.take(tid, pid) do
      [{_pid, postgres_id, _config, _claims, _ref}] ->
        Subscriptions.delete(state.conn, UUID.string_to_binary!(postgres_id))

      _ ->
        Logger.error("Undefined PID: #{inspect(pid)}")
        nil
    end

    {:noreply, state}
  end

  def handle_info({:unsubscribe, subs_id}, state) do
    Subscriptions.delete(state.conn, subs_id)
    {:noreply, state}
  end

  def handle_info(:check_active_pids, %{check_active_pids: ref, subscribers_tid: tid} = state) do
    cancel_timer(ref)

    objects =
      fn {pid, postgres_id, _config, _claims, _monitor_ref}, acc ->
        case :rpc.call(node(pid), Process, :alive?, [pid]) do
          true ->
            nil

          _ ->
            Logger.error("Detected phantom subscriber")
            :ets.delete(tid, pid)
            Subscriptions.delete(state.conn, UUID.string_to_binary!(postgres_id))
        end

        acc + 1
      end
      |> :ets.foldl(0, tid)

    new_ref =
      if objects == 0 do
        Logger.debug("Cancel check_active_pids")
        nil
      else
        check_active_pids()
      end

    {:noreply, %{state | check_active_pids: new_ref}}
  end

  defp check_active_pids() do
    Process.send_after(
      self(),
      :check_active_pids,
      @timeout
    )
  end

  defp check_oids() do
    Process.send_after(
      self(),
      :check_oids,
      @check_oids_interval
    )
  end
end
