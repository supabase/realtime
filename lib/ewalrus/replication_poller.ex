defmodule Ewalrus.ReplicationPoller do
  use GenServer

  require Logger

  alias Ewalrus.Replications
  alias DBConnection.Backoff

  alias Realtime.Adapters.Changes.{
    DeletedRecord,
    NewRecord,
    UpdatedRecord
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    state = %{
      backoff:
        Backoff.new(
          backoff_min: Keyword.fetch!(opts, :backoff_min),
          backoff_max: Keyword.fetch!(opts, :backoff_max),
          backoff_type: Keyword.fetch!(opts, :backoff_type)
        ),
      poll_interval: Keyword.fetch!(opts, :replication_poll_interval),
      poll_ref: make_ref(),
      publication: Keyword.fetch!(opts, :publication),
      slot_name: Keyword.fetch!(opts, :slot_name),
      max_record_bytes: Keyword.fetch!(opts, :max_record_bytes),
      conn: Keyword.fetch!(opts, :conn),
      id: Keyword.fetch!(opts, :id)
    }

    {:ok, state, {:continue, :prepare_replication}}
  end

  @impl true
  def handle_continue(
        :prepare_replication,
        %{backoff: backoff, slot_name: slot_name, conn: conn} = state
      ) do
    try do
      Replications.prepare_replication(conn, slot_name)
    catch
      :error, error -> {:error, error}
    end
    |> case do
      {:ok, {:ok, %{command: :set}}} ->
        send(self(), :poll)
        {:noreply, state}

      # TODO: check errors
      {:error, error} ->
        error
        |> IO.inspect()
        |> Logger.error()

        {timeout, backoff} = Backoff.backoff(backoff)
        :timer.sleep(timeout)

        {:noreply, %{state | backoff: backoff}, {:continue, :prepare_replication}}
    end
  end

  @impl true
  def handle_info(
        :poll,
        %{
          backoff: backoff,
          poll_interval: poll_interval,
          poll_ref: poll_ref,
          publication: publication,
          slot_name: slot_name,
          max_record_bytes: max_record_bytes,
          conn: conn,
          id: id
        } = state
      ) do
    Process.cancel_timer(poll_ref)

    try do
      Replications.list_changes(conn, slot_name, publication, max_record_bytes)
    catch
      :error, reason ->
        {:error, reason}
    end
    |> case do
      {:ok,
       %Postgrex.Result{
         columns: ["wal", "is_rls_enabled", "subscription_ids", "errors"] = columns,
         rows: [_ | _] = rows
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
        # |> Logger.debug()
        |> Enum.reverse()
        |> Ewalrus.SubscribersNotification.notify_subscribers(id)

      {:ok, _} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
    |> case do
      :ok ->
        backoff = Backoff.reset(backoff)
        poll_ref = Process.send_after(self(), :poll, poll_interval)

        {:noreply, %{state | backoff: backoff, poll_ref: poll_ref}}

      {:error, reason} ->
        reason
        |> inspect(pretty: true)
        |> Logger.error()

        {timeout, backoff} = Backoff.backoff(backoff)
        :timer.sleep(timeout)

        {:noreply, %{state | backoff: backoff}, {:continue, :prepare_replication}}
    end
  end

  def generate_record([
        {"wal",
         %{
           "type" => "INSERT" = type,
           "columns" => columns,
           "commit_timestamp" => commit_timestamp,
           "schema" => schema,
           "table" => table,
           "record" => record
         }},
        {"is_rls_enabled", is_rls_enabled},
        {"subscription_ids", subscription_ids},
        {"errors", errors}
      ])
      when is_boolean(is_rls_enabled) and is_list(subscription_ids) do
    %NewRecord{
      columns: columns,
      commit_timestamp: commit_timestamp,
      errors: convert_errors(errors),
      is_rls_enabled: is_rls_enabled,
      schema: schema,
      table: table,
      type: type,
      subscription_ids: MapSet.new(subscription_ids),
      record: record
    }
  end

  def generate_record([
        {"wal",
         %{
           "type" => "UPDATE" = type,
           "columns" => columns,
           "commit_timestamp" => commit_timestamp,
           "schema" => schema,
           "table" => table,
           "record" => record,
           "old_record" => old_record
         }},
        {"is_rls_enabled", is_rls_enabled},
        {"subscription_ids", subscription_ids},
        {"errors", errors}
      ])
      when is_boolean(is_rls_enabled) and is_list(subscription_ids) do
    %UpdatedRecord{
      columns: columns,
      commit_timestamp: commit_timestamp,
      errors: convert_errors(errors),
      is_rls_enabled: is_rls_enabled,
      schema: schema,
      table: table,
      type: type,
      subscription_ids: MapSet.new(subscription_ids),
      old_record: old_record,
      record: record
    }
  end

  def generate_record([
        {"wal",
         %{
           "type" => "DELETE" = type,
           "columns" => columns,
           "commit_timestamp" => commit_timestamp,
           "schema" => schema,
           "table" => table,
           "old_record" => old_record
         }},
        {"is_rls_enabled", is_rls_enabled},
        {"subscription_ids", subscription_ids},
        {"errors", errors}
      ])
      when is_boolean(is_rls_enabled) and is_list(subscription_ids) do
    %DeletedRecord{
      columns: columns,
      commit_timestamp: commit_timestamp,
      errors: convert_errors(errors),
      is_rls_enabled: is_rls_enabled,
      schema: schema,
      table: table,
      type: type,
      subscription_ids: MapSet.new(subscription_ids),
      old_record: old_record
    }
  end

  def generate_record(_), do: nil

  defp convert_errors([_ | _] = errors), do: errors

  defp convert_errors(_), do: nil
end
