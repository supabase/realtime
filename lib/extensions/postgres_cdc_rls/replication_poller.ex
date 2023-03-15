defmodule Extensions.PostgresCdcRls.ReplicationPoller do
  @moduledoc """
  Polls the write ahead log, applies row level sucurity policies for each subscriber
  and broadcast records to the `MessageDispatcher`.
  """

  use GenServer

  require Logger

  import Realtime.Helpers, only: [cancel_timer: 1, decrypt_creds: 5]

  alias Extensions.PostgresCdcRls.{Replications, MessageDispatcher}
  alias DBConnection.Backoff
  alias Realtime.PubSub

  alias Realtime.Adapters.Changes.{
    DeletedRecord,
    NewRecord,
    UpdatedRecord
  }

  @queue_target 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(args) do
    {:ok, conn} =
      connect_db(
        args["db_host"],
        args["db_port"],
        args["db_name"],
        args["db_user"],
        args["db_password"],
        args["db_socket_opts"]
      )

    tenant = args["id"]

    state = %{
      backoff:
        Backoff.new(
          backoff_min: 100,
          backoff_max: 5_000,
          backoff_type: :rand_exp
        ),
      conn: conn,
      db_host: args["db_host"],
      db_port: args["db_port"],
      db_name: args["db_name"],
      db_user: args["db_user"],
      db_pass: args["db_password"],
      db_socket_opts: args["db_socket_opts"],
      max_changes: args["poll_max_changes"],
      max_record_bytes: args["poll_max_record_bytes"],
      poll_interval_ms: args["poll_interval_ms"],
      poll_ref: nil,
      publication: args["publication"],
      retry_ref: nil,
      retry_count: 0,
      slot_name: args["slot_name"] <> slot_name_suffix(),
      tenant: tenant
    }

    Logger.metadata(external_id: tenant, project: tenant)

    {:ok, state, {:continue, :prepare}}
  end

  @impl true
  def handle_continue(:prepare, state) do
    {:noreply, prepare_replication(state)}
  end

  @impl true
  def handle_info(
        :poll,
        %{
          backoff: backoff,
          poll_interval_ms: poll_interval_ms,
          poll_ref: poll_ref,
          publication: publication,
          retry_ref: retry_ref,
          retry_count: retry_count,
          slot_name: slot_name,
          max_record_bytes: max_record_bytes,
          max_changes: max_changes,
          conn: conn,
          tenant: tenant
        } = state
      ) do
    cancel_timer(poll_ref)
    cancel_timer(retry_ref)

    try do
      {time, response} =
        :timer.tc(Replications, :list_changes, [
          conn,
          slot_name,
          publication,
          max_changes,
          max_record_bytes
        ])

      Realtime.Telemetry.execute(
        [:realtime, :replication, :poller, :query, :stop],
        %{duration: time},
        %{tenant: tenant}
      )

      response
    catch
      {:error, reason} ->
        {:error, reason}
    end
    |> case do
      {:ok,
       %Postgrex.Result{
         columns: ["wal", "is_rls_enabled", "subscription_ids", "errors"] = columns,
         rows: [_ | _] = rows,
         num_rows: rows_count
       }} ->
        Enum.reduce(rows, [], fn row, acc ->
          columns
          |> Enum.zip(row)
          |> generate_record()
          |> case do
            nil ->
              acc

            record_struct ->
              [record_struct | acc]
          end
        end)
        |> Enum.reverse()
        |> Enum.each(fn change ->
          Phoenix.PubSub.broadcast_from(
            PubSub,
            self(),
            "realtime:postgres:" <> tenant,
            change,
            MessageDispatcher
          )
        end)

        {:ok, rows_count}

      {:ok, _} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
    |> case do
      {:ok, rows_num} ->
        backoff = Backoff.reset(backoff)

        poll_ref =
          if rows_num > 0 do
            send(self(), :poll)
            nil
          else
            Process.send_after(self(), :poll, poll_interval_ms)
          end

        {:noreply, %{state | backoff: backoff, poll_ref: poll_ref}}

      {:error, %Postgrex.Error{postgres: %{code: :object_in_use, message: msg}}} ->
        Logger.error("Error polling replication: :object_in_use")

        [_, db_pid] = Regex.run(~r/PID\s(\d*)$/, msg)
        db_pid = String.to_integer(db_pid)

        {:ok, diff} = Replications.get_pg_stat_activity_diff(conn, db_pid)

        Logger.warn(
          "Database PID #{db_pid} found in pg_stat_activity with state_change diff of #{diff}"
        )

        if retry_count > 3 do
          case Replications.terminate_backend(conn, slot_name) do
            {:ok, :terminated} ->
              Logger.warn("Replication slot in use - terminating")

            {:error, :slot_not_found} ->
              Logger.warn("Replication slot not found")

            {:error, error} ->
              Logger.warn("Error terminating backend: #{inspect(error)}")
          end
        end

        {timeout, backoff} = Backoff.backoff(backoff)
        retry_ref = Process.send_after(self(), :retry, timeout)

        {:noreply,
         %{state | backoff: backoff, retry_ref: retry_ref, retry_count: retry_count + 1}}

      {:error, reason} ->
        Logger.error("Error polling replication: #{inspect(reason, pretty: true)}")

        {timeout, backoff} = Backoff.backoff(backoff)
        retry_ref = Process.send_after(self(), :retry, timeout)

        {:noreply,
         %{state | backoff: backoff, retry_ref: retry_ref, retry_count: retry_count + 1}}
    end
  end

  @impl true
  def handle_info(:retry, %{retry_ref: retry_ref} = state) do
    cancel_timer(retry_ref)
    {:noreply, prepare_replication(state)}
  end

  def generate_record([
        {"wal",
         %{
           "type" => "INSERT" = type,
           "schema" => schema,
           "table" => table
         } = wal},
        {"is_rls_enabled", _},
        {"subscription_ids", subscription_ids},
        {"errors", errors}
      ])
      when is_list(subscription_ids) do
    %NewRecord{
      columns: Map.get(wal, "columns", []),
      commit_timestamp: Map.get(wal, "commit_timestamp"),
      errors: convert_errors(errors),
      schema: schema,
      table: table,
      type: type,
      subscription_ids: MapSet.new(subscription_ids),
      record: Map.get(wal, "record", %{})
    }
  end

  def generate_record([
        {"wal",
         %{
           "type" => "UPDATE" = type,
           "schema" => schema,
           "table" => table
         } = wal},
        {"is_rls_enabled", _},
        {"subscription_ids", subscription_ids},
        {"errors", errors}
      ])
      when is_list(subscription_ids) do
    %UpdatedRecord{
      columns: Map.get(wal, "columns", []),
      commit_timestamp: Map.get(wal, "commit_timestamp"),
      errors: convert_errors(errors),
      schema: schema,
      table: table,
      type: type,
      subscription_ids: MapSet.new(subscription_ids),
      old_record: Map.get(wal, "old_record", %{}),
      record: Map.get(wal, "record", %{})
    }
  end

  def generate_record([
        {"wal",
         %{
           "type" => "DELETE" = type,
           "schema" => schema,
           "table" => table
         } = wal},
        {"is_rls_enabled", _},
        {"subscription_ids", subscription_ids},
        {"errors", errors}
      ])
      when is_list(subscription_ids) do
    %DeletedRecord{
      columns: Map.get(wal, "columns", []),
      commit_timestamp: Map.get(wal, "commit_timestamp"),
      errors: convert_errors(errors),
      schema: schema,
      table: table,
      type: type,
      subscription_ids: MapSet.new(subscription_ids),
      old_record: Map.get(wal, "old_record", %{})
    }
  end

  def generate_record(_), do: nil

  def slot_name_suffix() do
    case System.get_env("SLOT_NAME_SUFFIX") do
      nil ->
        ""

      value ->
        Logger.debug("Using slot name suffix: " <> value)
        "_" <> value
    end
  end

  defp convert_errors([_ | _] = errors), do: errors

  defp convert_errors(_), do: nil

  defp connect_db(host, port, name, user, pass, socket_opts) do
    {host, port, name, user, pass} = decrypt_creds(host, port, name, user, pass)

    Postgrex.start_link(
      hostname: host,
      port: port,
      database: name,
      password: pass,
      username: user,
      queue_target: @queue_target,
      parameters: [
        application_name: "realtime_rls"
      ],
      socket_options: socket_opts
    )
  end

  defp prepare_replication(
         %{backoff: backoff, conn: conn, slot_name: slot_name, retry_count: retry_count} = state
       ) do
    case Replications.prepare_replication(conn, slot_name) do
      {:ok, _} ->
        send(self(), :poll)
        state

      {:error, error} ->
        Logger.error("Prepare replication error: #{inspect(error)}")
        {timeout, backoff} = Backoff.backoff(backoff)
        retry_ref = Process.send_after(self(), :retry, timeout)
        %{state | backoff: backoff, retry_ref: retry_ref, retry_count: retry_count + 1}
    end
  end
end
