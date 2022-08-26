defmodule Extensions.Postgres.ReplicationPoller do
  use GenServer

  require Logger

  import Realtime.Helpers, only: [cancel_timer: 1, decrypt!: 2]

  alias Extensions.Postgres
  alias Postgres.Replications

  alias Realtime.{MessageDispatcher, PubSub, Repo}

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
    state = %{
      conn: nil,
      db_host: args["db_host"],
      db_name: args["db_name"],
      db_user: args["db_user"],
      db_pass: args["db_password"],
      max_changes: args["poll_max_changes"],
      max_record_bytes: args["poll_max_record_bytes"],
      poll_interval_ms: args["poll_interval_ms"],
      poll_ref: make_ref(),
      publication: args["publication"],
      slot_name: args["slot_name"],
      tenant: args["id"]
    }

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
          slot_name: slot_name
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
        |> Enum.each(fn change ->
          Phoenix.PubSub.broadcast_from(
            PubSub,
            self(),
            "realtime:postgres:" <> tenant,
            change,
            MessageDispatcher
          )
        end)

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

  defp convert_errors([_ | _] = errors), do: errors

  defp convert_errors(_), do: nil
end
