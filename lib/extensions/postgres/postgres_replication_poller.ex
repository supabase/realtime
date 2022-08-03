defmodule Extensions.Postgres.ReplicationPoller do
  use GenServer

  require Logger

  import Realtime.Helpers, only: [cancel_timer: 1, decrypt!: 2]

  alias Extensions.Postgres
  alias Postgres.Replications

  alias Realtime.Adapters.Changes.{
    DeletedRecord,
    NewRecord,
    UpdatedRecord
  }

  alias Realtime.Repo

  @queue_target 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    id = Keyword.fetch!(opts, :id)

    state = %{
      conn: nil,
      db_host: Keyword.fetch!(opts, :db_host),
      db_name: Keyword.fetch!(opts, :db_name),
      db_pass: Keyword.fetch!(opts, :db_pass),
      db_user: Keyword.fetch!(opts, :db_user),
      max_changes: Keyword.fetch!(opts, :max_changes),
      max_record_bytes: Keyword.fetch!(opts, :max_record_bytes),
      poll_interval_ms: Keyword.fetch!(opts, :poll_interval_ms),
      poll_ref: make_ref(),
      publication: Keyword.fetch!(opts, :publication),
      slot_name: Keyword.fetch!(opts, :slot_name),
      tenant: id
    }

    Process.put(:tenant, id)
    {:ok, state, {:continue, :prepare_replication}}
  end

  @impl true
  def handle_continue(
        :prepare_replication,
        %{
          db_host: db_host,
          db_name: db_name,
          db_pass: db_pass,
          db_user: db_user,
          slot_name: slot_name,
          tenant: tenant
        } = state
      ) do
    secure_key = Application.get_env(:realtime, :db_enc_key)
    db_host = decrypt!(db_host, secure_key)
    db_name = decrypt!(db_name, secure_key)
    db_pass = decrypt!(db_pass, secure_key)
    db_user = decrypt!(db_user, secure_key)

    Repo.with_dynamic_repo(
      [hostname: db_host, database: db_name, password: db_pass, username: db_user],
      fn repo ->
        Ecto.Migrator.run(
          Repo,
          [Ecto.Migrator.migrations_path(Repo, "postgres/migrations")],
          :up,
          all: true,
          prefix: "realtime",
          dynamic_repo: repo
        )
      end
    )

    {:ok, conn} =
      Postgrex.start_link(
        hostname: db_host,
        database: db_name,
        password: db_pass,
        username: db_user,
        queue_target: @queue_target,
        parameters: [
          application_name: "realtime_rls"
        ]
      )

    {:ok, _} = Replications.prepare_replication(conn, slot_name)

    :yes = :global.register_name({:tenant_db, :replication, :poller, tenant}, conn)

    send(self(), :poll)

    {:noreply, %{state | conn: conn}}
  end

  @impl true
  def handle_info(
        :poll,
        %{
          poll_interval_ms: poll_interval_ms,
          poll_ref: poll_ref,
          publication: publication,
          slot_name: slot_name,
          max_record_bytes: max_record_bytes,
          max_changes: max_changes,
          conn: conn,
          tenant: tenant
        } = state
      ) do
    cancel_timer(poll_ref)

    try do
      Replications.list_changes(conn, slot_name, publication, max_changes, max_record_bytes)
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
        |> Enum.reverse()
        |> Postgres.SubscribersNotification.notify_subscribers(tenant)

        {:ok, length(rows)}

      {:ok, _} ->
        {:ok, 0}

      {:error, reason} ->
        {:error, reason}
    end
    |> case do
      {:ok, rows_num} ->
        poll_ref =
          if rows_num > 0 do
            send(self(), :poll)
            nil
          else
            Process.send_after(self(), :poll, poll_interval_ms)
          end

        {:noreply, %{state | poll_ref: poll_ref}}

      {:error, reason} ->
        {:stop, inspect(reason, pretty: true), state}
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
