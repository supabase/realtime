defmodule Extensions.Postgres.SubscriptionManager do
  @moduledoc """
  Handles subscriptions from multiple databases.
  """
  use GenServer
  require Logger

  alias Extensions.Postgres
  alias Postgres.Subscriptions
  alias Realtime.Helpers, as: H

  @check_oids_interval 60_000
  @timeout 15_000
  @max_delete_records 100

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Callbacks

  @impl true
  def init(args) do
    %{
      "id" => id,
      "publication" => publication,
      "subscribers_tid" => subscribers_tid,
      "db_host" => host,
      "db_port" => port,
      "db_name" => name,
      "db_user" => user,
      "db_password" => pass,
      "db_socket_opts" => socket_opts
    } = args

    {:ok, conn} = H.connect_db(host, port, name, user, pass, socket_opts, 1)
    {:ok, conn_pub} = H.connect_db(host, port, name, user, pass, socket_opts)
    {:ok, _} = Subscriptions.maybe_delete_all(conn)

    state = %{
      id: id,
      oids: %{},
      conn: conn,
      check_oid_ref: nil,
      publication: publication,
      subscribers_tid: subscribers_tid,
      delete_queue: %{
        ref: check_delete_queue(),
        queue: :queue.new()
      }
    }

    send(self(), :check_oids)
    Postgres.track_manager(id, self(), conn_pub)
    {:ok, state}
  end

  @impl true
  def handle_info({:subscribed, {pid, id}}, state) do
    true =
      state.subscribers_tid
      |> :ets.insert({pid, id, Process.monitor(pid)})

    {:noreply, state}
  end

  def handle_info(
        :check_oids,
        %{check_oid_ref: ref, conn: conn, publication: publication, oids: old_oids} = state
      ) do
    H.cancel_timer(ref)

    oids =
      case Subscriptions.fetch_publication_tables(conn, publication) do
        ^old_oids ->
          old_oids

        new_oids ->
          Logger.warning("Found new oids #{inspect(new_oids, pretty: true)}")
          Subscriptions.delete_all(conn)

          fn {pid, _id, ref}, _acc ->
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
        %{subscribers_tid: tid, delete_queue: %{queue: q}} = state
      ) do
    q1 =
      case :ets.take(tid, pid) do
        [] ->
          q

        values ->
          for {_pid, id, _ref} <- values, reduce: q do
            acc ->
              UUID.string_to_binary!(id)
              |> :queue.in(acc)
          end
      end

    {:noreply, put_in(state.delete_queue.queue, q1)}
  end

  def handle_info(:check_delete_queue, %{delete_queue: %{ref: ref, queue: q}} = state) do
    H.cancel_timer(ref)

    q1 =
      if !:queue.is_empty(q) do
        {ids, q1} = queue_take(q, @max_delete_records)
        Logger.debug("delete sub id #{inspect(ids)}")
        Subscriptions.delete_multi(state.conn, ids)
        q1
      else
        q
      end

    {:noreply, %{state | delete_queue: %{ref: check_delete_queue(), queue: q1}}}
  end

  def handle_info(msg, state) do
    Logger.error("Undef msg #{inspect(msg, pretty: true)}")
    {:noreply, state}
  end

  ## Internal functions

  def queue_take(q, count) do
    Enum.reduce_while(0..count, {[], q}, fn _, {items, queue} ->
      case :queue.out(queue) do
        {{:value, item}, new_q} ->
          {:cont, {[item | items], new_q}}

        {:empty, new_q} ->
          {:halt, {items, new_q}}
      end
    end)
  end

  defp check_delete_queue() do
    Process.send_after(
      self(),
      :check_delete_queue,
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
