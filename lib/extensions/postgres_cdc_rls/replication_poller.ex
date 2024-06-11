defmodule Extensions.PostgresCdcRls.ReplicationPoller do
  @moduledoc """
  Polls the write ahead log, applies row level sucurity policies for each subscriber
  and broadcast records to the `MessageDispatcher`.
  """

  use GenServer

  require Logger

  import Realtime.Helpers,
    only: [cancel_timer: 1, log_error: 2, to_log: 1]

  alias DBConnection.Backoff

  alias Extensions.PostgresCdcRls.MessageDispatcher
  alias Extensions.PostgresCdcRls.Replications

  alias Realtime.Adapters.Changes.DeletedRecord
  alias Realtime.Adapters.Changes.NewRecord
  alias Realtime.Adapters.Changes.UpdatedRecord
  alias Realtime.Database
  alias Realtime.PubSub

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(args) do
    tenant = args["id"]
    Logger.metadata(external_id: tenant, project: tenant)

    # higher number of pool connections leads to issues
    realtime_rls_settings =
      args
      |> Database.from_settings("realtime_rls")
      |> Map.put(:pool, 1)

    {:ok, conn} = Database.connect_db(realtime_rls_settings)

    state = %{
      backoff: Backoff.new(backoff_min: 100, backoff_max: 5_000, backoff_type: :rand_exp),
      conn: conn,
      db_host: args["db_host"],
      db_port: args["db_port"],
      db_name: args["db_name"],
      db_user: args["db_user"],
      db_pass: args["db_password"],
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

    args = [conn, slot_name, publication, max_changes, max_record_bytes]
    {time, list_changes} = :timer.tc(Replications, :list_changes, args)
    record_list_changes_telemetry(time, tenant)

    case handle_list_changes_result(list_changes, tenant) do
      {:ok, row_count} ->
        Backoff.reset(backoff)

        pool_ref =
          if row_count > 0 do
            send(self(), :poll)
            nil
          else
            Process.send_after(self(), :poll, poll_interval_ms)
          end

        {:noreply, %{state | backoff: backoff, poll_ref: pool_ref}}

      {:error, %Postgrex.Error{postgres: %{code: :object_in_use, message: msg}}} ->
        log_error("ReplicationSlotBeingUsed", msg)
        [_, db_pid] = Regex.run(~r/PID\s(\d*)$/, msg)
        db_pid = String.to_integer(db_pid)

        {:ok, diff} = Replications.get_pg_stat_activity_diff(conn, db_pid)

        Logger.warning(
          "Database PID #{db_pid} found in pg_stat_activity with state_change diff of #{diff}"
        )

        if retry_count > 3 do
          case Replications.terminate_backend(conn, slot_name) do
            {:ok, :terminated} -> Logger.warning("Replication slot in use - terminating")
            {:error, :slot_not_found} -> Logger.warning("Replication slot not found")
            {:error, error} -> Logger.warning("Error terminating backend: #{inspect(error)}")
          end
        end

        {timeout, backoff} = Backoff.backoff(backoff)
        retry_ref = Process.send_after(self(), :retry, timeout)

        {:noreply,
         %{state | backoff: backoff, retry_ref: retry_ref, retry_count: retry_count + 1}}

      {:error, reason} ->
        Logger.error(%{error_code: "PoolingReplicationError", error_message: to_log(reason)})

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

  def slot_name_suffix() do
    case Application.get_env(:realtime, :slot_name_suffix) do
      nil -> ""
      slot_name_suffix -> "_" <> slot_name_suffix
    end
  end

  defp convert_errors([_ | _] = errors), do: errors

  defp convert_errors(_), do: nil

  defp prepare_replication(
         %{backoff: backoff, conn: conn, slot_name: slot_name, retry_count: retry_count} = state
       ) do
    case Replications.prepare_replication(conn, slot_name) do
      {:ok, _} ->
        send(self(), :poll)
        state

      {:error, error} ->
        log_error("PoolingReplicationPreparationError", error)

        {timeout, backoff} = Backoff.backoff(backoff)
        retry_ref = Process.send_after(self(), :retry, timeout)
        %{state | backoff: backoff, retry_ref: retry_ref, retry_count: retry_count + 1}
    end
  end

  defp record_list_changes_telemetry(time, tenant) do
    Realtime.Telemetry.execute(
      [:realtime, :replication, :poller, :query, :stop],
      %{duration: time},
      %{tenant: tenant}
    )
  end

  defp handle_list_changes_result(
         {:ok,
          %Postgrex.Result{
            columns: ["wal", "is_rls_enabled", "subscription_ids", "errors"] = columns,
            rows: [_ | _] = rows,
            num_rows: rows_count
          }},
         tenant
       ) do
    for row <- rows,
        change <- columns |> Enum.zip(row) |> generate_record() |> List.wrap() do
      topic = "realtime:postgres:" <> tenant
      Phoenix.PubSub.broadcast_from(PubSub, self(), topic, change, MessageDispatcher)
    end

    {:ok, rows_count}
  end

  defp handle_list_changes_result({:ok, _}, _), do: {:ok, 0}
  defp handle_list_changes_result({:error, reason}, _), do: {:error, reason}

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
end
