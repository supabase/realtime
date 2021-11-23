defmodule Realtime.RLS.ReplicationPoller do
  use GenServer

  require Logger

  alias DBConnection.Backoff

  alias Realtime.Adapters.Changes.{
    DeletedRecord,
    NewRecord,
    UpdatedRecord
  }

  alias Realtime.SubscribersNotification
  alias Realtime.RLS.Replications

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
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
      temporary_slot: Keyword.fetch!(opts, :temporary_slot),
      max_record_bytes: Keyword.fetch!(opts, :max_record_bytes)
    }

    {:ok, state, {:continue, :prepare_replication}}
  end

  @impl true
  def handle_continue(
        :prepare_replication,
        %{backoff: backoff, slot_name: slot_name, temporary_slot: temporary_slot} = state
      ) do
    try do
      Replications.prepare_replication(slot_name, temporary_slot)
    catch
      :error, error -> {:error, error}
    end
    |> case do
      {:ok, %{create_slot: ^slot_name, search_path: :set}} ->
        send(self(), :poll)
        {:noreply, state}

      {:error, error} ->
        error
        |> inspect()
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
          max_record_bytes: max_record_bytes
        } = state
      ) do
    Process.cancel_timer(poll_ref)

    try do
      Replications.list_changes(slot_name, publication, max_record_bytes)
    catch
      :error, error -> {:error, error}
    end
    |> case do
      {:ok,
       %{columns: ["wal", "is_rls_enabled", "users", "errors"] = columns, rows: [_ | _] = rows}} ->
        Enum.each(rows, fn row ->
          columns
          |> Enum.zip(row)
          |> generate_record()
          |> case do
            nil ->
              :ok

            record_struct ->
              :ok = SubscribersNotification.notify([record_struct])
          end
        end)

      {:ok, _} ->
        :ok

      {:error, error} ->
        {:error, error}
    end
    |> case do
      :ok ->
        backoff = Backoff.reset(backoff)
        poll_ref = Process.send_after(self(), :poll, poll_interval)

        {:noreply, %{state | backoff: backoff, poll_ref: poll_ref}}

      {:error, error} ->
        error
        |> inspect()
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
        {"users", users},
        {"errors", errors}
      ])
      when is_boolean(is_rls_enabled) and is_list(users) do
    %NewRecord{
      columns: columns,
      commit_timestamp: commit_timestamp,
      errors: convert_errors(errors),
      is_rls_enabled: is_rls_enabled,
      schema: schema,
      table: table,
      type: type,
      users: MapSet.new(users),
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
        {"users", users},
        {"errors", errors}
      ])
      when is_boolean(is_rls_enabled) and is_list(users) do
    %UpdatedRecord{
      columns: columns,
      commit_timestamp: commit_timestamp,
      errors: convert_errors(errors),
      is_rls_enabled: is_rls_enabled,
      schema: schema,
      table: table,
      type: type,
      users: MapSet.new(users),
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
        {"users", users},
        {"errors", errors}
      ])
      when is_boolean(is_rls_enabled) and is_list(users) do
    %DeletedRecord{
      columns: columns,
      commit_timestamp: commit_timestamp,
      errors: convert_errors(errors),
      is_rls_enabled: is_rls_enabled,
      schema: schema,
      table: table,
      type: type,
      users: MapSet.new(users),
      old_record: old_record
    }
  end

  def generate_record(_), do: nil

  defp convert_errors([_ | _] = errors), do: errors

  defp convert_errors(_), do: nil
end
