defmodule Extensions.PostgresCdcRls.SubscriptionManager do
  @moduledoc """
  Handles subscriptions from tenant's database.
  """
  use GenServer
  use Realtime.Logs

  alias Realtime.Tenants.Rebalancer
  alias Extensions.PostgresCdcRls, as: Rls

  alias Realtime.Database
  alias Realtime.Helpers

  alias Rls.Subscriptions

  @timeout 15_000
  @max_delete_records 1000
  @check_oids_interval 60_000
  @check_no_users_interval 60_000
  @stop_after 60_000 * 10

  defmodule State do
    @moduledoc false
    defstruct [
      :id,
      :publication,
      :subscribers_pids_table,
      :subscribers_nodes_table,
      :conn,
      :delete_queue,
      :no_users_ref,
      no_users_ts: nil,
      oids: %{},
      check_oid_ref: nil,
      check_region_interval: nil
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            publication: String.t(),
            subscribers_pids_table: :ets.tid(),
            subscribers_nodes_table: :ets.tid(),
            conn: Postgrex.conn(),
            oids: map(),
            check_oid_ref: reference() | nil,
            delete_queue: %{
              ref: reference(),
              queue: :queue.queue()
            },
            no_users_ref: reference(),
            no_users_ts: non_neg_integer() | nil,
            check_region_interval: non_neg_integer
          }
  end

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Callbacks

  @impl true
  def init(args) do
    %{"id" => id} = args
    Logger.metadata(external_id: id, project: id)
    {:ok, nil, {:continue, {:connect, args}}}
  end

  @impl true
  def handle_continue({:connect, args}, _) do
    %{
      "id" => id,
      "publication" => publication,
      "subscribers_pids_table" => subscribers_pids_table,
      "subscribers_nodes_table" => subscribers_nodes_table
    } = args

    subscription_manager_settings = Database.from_settings(args, "realtime_subscription_manager")

    subscription_manager_pub_settings =
      Database.from_settings(args, "realtime_subscription_manager_pub")

    {:ok, conn} = Database.connect_db(subscription_manager_settings)
    {:ok, conn_pub} = Database.connect_db(subscription_manager_pub_settings)
    {:ok, _} = Subscriptions.maybe_delete_all(conn)

    Rls.update_meta(id, self(), conn_pub)

    oids = Subscriptions.fetch_publication_tables(conn, publication)

    check_region_interval = Map.get(args, :check_region_interval, rebalance_check_interval_in_ms())
    send_region_check_message(check_region_interval)

    state =
      %State{
        id: id,
        conn: conn,
        publication: publication,
        subscribers_pids_table: subscribers_pids_table,
        subscribers_nodes_table: subscribers_nodes_table,
        oids: oids,
        delete_queue: %{
          ref: check_delete_queue(),
          queue: :queue.new()
        },
        no_users_ref: check_no_users(),
        check_region_interval: check_region_interval
      }

    send(self(), :check_oids)
    {:noreply, state}
  end

  @impl true
  def handle_info({:subscribed, {pid, id}}, state) do
    case :ets.match(state.subscribers_pids_table, {pid, id, :"$1", :_}) do
      [] -> :ets.insert(state.subscribers_pids_table, {pid, id, Process.monitor(pid), node(pid)})
      _ -> :ok
    end

    :ets.insert(state.subscribers_nodes_table, {UUID.string_to_binary!(id), node(pid)})

    {:noreply, %{state | no_users_ts: nil}}
  end

  def handle_info(
        :check_oids,
        %State{check_oid_ref: ref, conn: conn, publication: publication, oids: old_oids} = state
      ) do
    Helpers.cancel_timer(ref)

    oids =
      case Subscriptions.fetch_publication_tables(conn, publication) do
        ^old_oids ->
          old_oids

        new_oids ->
          Logger.warning("Found new oids #{inspect(new_oids, pretty: true)}")
          Subscriptions.delete_all(conn)

          fn {pid, _id, ref, _node}, _acc ->
            Process.demonitor(ref, [:flush])
            send(pid, :postgres_subscribe)
          end
          |> :ets.foldl([], state.subscribers_pids_table)

          new_oids
      end

    {:noreply, %{state | oids: oids, check_oid_ref: check_oids()}}
  end

  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        %State{
          subscribers_pids_table: subscribers_pids_table,
          subscribers_nodes_table: subscribers_nodes_table,
          delete_queue: %{queue: q}
        } = state
      ) do
    q1 =
      case :ets.take(subscribers_pids_table, pid) do
        [] ->
          q

        values ->
          for {_pid, id, _ref, _node} <- values, reduce: q do
            acc ->
              bin_id = UUID.string_to_binary!(id)

              :ets.delete(subscribers_nodes_table, bin_id)

              :queue.in(bin_id, acc)
          end
      end

    {:noreply, put_in(state.delete_queue.queue, q1)}
  end

  def handle_info(:check_delete_queue, %State{delete_queue: %{ref: ref, queue: q}} = state) do
    Helpers.cancel_timer(ref)

    q1 =
      if :queue.is_empty(q) do
        q
      else
        {ids, q1} = Helpers.queue_take(q, @max_delete_records)
        Logger.debug("delete sub id #{inspect(ids)}")

        case Subscriptions.delete_multi(state.conn, ids) do
          {:ok, _} ->
            q1

          {:error, reason} ->
            log_error("SubscriptionDeletionFailed", reason)

            q
        end
      end

    ref = if :queue.is_empty(q1), do: check_delete_queue(), else: check_delete_queue(1_000)

    {:noreply, %{state | delete_queue: %{ref: ref, queue: q1}}}
  end

  def handle_info(:check_no_users, %{subscribers_pids_table: tid, no_users_ts: ts} = state) do
    Helpers.cancel_timer(state.no_users_ref)

    ts_new =
      case {:ets.info(tid, :size), ts != nil && ts + @stop_after < now()} do
        {0, true} ->
          Logger.info("Stop tenant #{state.id} because of no connected users")
          Rls.handle_stop(state.id, 15_000)
          ts

        {0, false} ->
          if ts != nil, do: ts, else: now()

        _ ->
          nil
      end

    {:noreply, %{state | no_users_ts: ts_new, no_users_ref: check_no_users()}}
  end

  def handle_info({:check_region, previous_nodes_set}, state) do
    current_nodes_set = MapSet.new(Node.list())

    case Rebalancer.check(previous_nodes_set, current_nodes_set, state.id) do
      :ok ->
        # Let's check again in the future
        send_region_check_message(state.check_region_interval)
        {:noreply, state}

      {:error, :wrong_region} ->
        Logger.warning("Rebalancing Postgres Changes replication for a closer region")
        Rls.handle_stop(state.id, 15_000)
        {:noreply, state}
    end
  end

  def handle_info(msg, state) do
    log_error("UnhandledProcessMessage", msg)

    {:noreply, state}
  end

  ## Internal functions

  defp check_oids, do: Process.send_after(self(), :check_oids, @check_oids_interval)

  defp now, do: System.system_time(:millisecond)

  defp check_no_users, do: Process.send_after(self(), :check_no_users, @check_no_users_interval)

  defp check_delete_queue(timeout \\ @timeout),
    do: Process.send_after(self(), :check_delete_queue, timeout)

  defp send_region_check_message(check_region_interval) do
    Process.send_after(self(), {:check_region, MapSet.new(Node.list())}, check_region_interval)
  end

  defp rebalance_check_interval_in_ms(), do: Application.fetch_env!(:realtime, :rebalance_check_interval_in_ms)
end
