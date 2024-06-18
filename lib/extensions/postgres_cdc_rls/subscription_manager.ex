defmodule Extensions.PostgresCdcRls.SubscriptionManager do
  @moduledoc """
  Handles subscriptions from tenant's database.
  """
  use GenServer
  require Logger

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
      :subscribers_tid,
      :conn,
      :delete_queue,
      :no_users_ref,
      no_users_ts: nil,
      oids: %{},
      check_oid_ref: nil
    ]

    @type t :: %__MODULE__{
            id: String.t(),
            publication: String.t(),
            subscribers_tid: :ets.tid(),
            conn: Postgrex.conn(),
            oids: map(),
            check_oid_ref: reference() | nil,
            delete_queue: %{
              ref: reference(),
              queue: :queue.queue()
            },
            no_users_ref: reference(),
            no_users_ts: non_neg_integer() | nil
          }
  end

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Callbacks

  @impl true
  def init(args) do
    %{"id" => id, "publication" => publication, "subscribers_tid" => subscribers_tid} = args
    Logger.metadata(external_id: id, project: id)

    subscription_manager_settings = Database.from_settings(args, "realtime_subscription_manager")

    subscription_manager_pub_settings =
      Database.from_settings(args, "realtime_subscription_manager_pub")

    {:ok, conn} = Database.connect_db(subscription_manager_settings)
    {:ok, conn_pub} = Database.connect_db(subscription_manager_pub_settings)
    {:ok, _} = Subscriptions.maybe_delete_all(conn)

    Rls.update_meta(id, self(), conn_pub)

    oids = Subscriptions.fetch_publication_tables(conn, publication)

    state = %State{
      id: id,
      conn: conn,
      publication: publication,
      subscribers_tid: subscribers_tid,
      oids: oids,
      delete_queue: %{
        ref: check_delete_queue(),
        queue: :queue.new()
      },
      no_users_ref: check_no_users()
    }

    send(self(), :check_oids)
    {:ok, state}
  end

  @impl true
  def handle_info({:subscribed, {pid, id}}, state) do
    case :ets.match(state.subscribers_tid, {pid, id, :"$1", :_}) do
      [] ->
        state.subscribers_tid
        |> :ets.insert({pid, id, Process.monitor(pid), node(pid)})

      _ ->
        :ok
    end

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
          |> :ets.foldl([], state.subscribers_tid)

          new_oids
      end

    {:noreply, %{state | oids: oids, check_oid_ref: check_oids()}}
  end

  def handle_info(
        {:DOWN, _ref, :process, pid, _reason},
        %State{subscribers_tid: tid, delete_queue: %{queue: q}} = state
      ) do
    q1 =
      case :ets.take(tid, pid) do
        [] ->
          q

        values ->
          for {_pid, id, _ref, _node} <- values, reduce: q do
            acc ->
              id
              |> UUID.string_to_binary!()
              |> :queue.in(acc)
          end
      end

    {:noreply, put_in(state.delete_queue.queue, q1)}
  end

  def handle_info(:check_delete_queue, %State{delete_queue: %{ref: ref, queue: q}} = state) do
    Helpers.cancel_timer(ref)

    q1 =
      if !:queue.is_empty(q) do
        {ids, q1} = Helpers.queue_take(q, @max_delete_records)
        Logger.debug("delete sub id #{inspect(ids)}")

        case Subscriptions.delete_multi(state.conn, ids) do
          {:ok, _} ->
            q1

          {:error, reason} ->
            Helpers.log_error("SubscriptionDeletionFailed", reason)

            q
        end
      else
        q
      end

    ref =
      if :queue.is_empty(q1) do
        check_delete_queue()
      else
        check_delete_queue(1_000)
      end

    {:noreply, %{state | delete_queue: %{ref: ref, queue: q1}}}
  end

  def handle_info(:check_no_users, %{subscribers_tid: tid, no_users_ts: ts} = state) do
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

  def handle_info(msg, state) do
    Helpers.log_error("UnhandledProcessMessage", msg)

    {:noreply, state}
  end

  ## Internal functions

  defp check_delete_queue(timeout \\ @timeout) do
    Process.send_after(
      self(),
      :check_delete_queue,
      timeout
    )
  end

  defp check_oids() do
    Process.send_after(
      self(),
      :check_oids,
      @check_oids_interval
    )
  end

  defp now() do
    System.system_time(:millisecond)
  end

  defp check_no_users() do
    Process.send_after(
      self(),
      :check_no_users,
      @check_no_users_interval
    )
  end
end
