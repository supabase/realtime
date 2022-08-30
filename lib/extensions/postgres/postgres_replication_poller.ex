defmodule Extensions.Postgres.ReplicationPoller do
  use GenServer

  require Logger

  import Realtime.Helpers, only: [cancel_timer: 1, decrypt!: 2]

  alias Extensions.Postgres
  alias Postgres.Replications
  alias DBConnection.Backoff

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
    {:ok, conn} =
      connect_db(
        args["db_host"],
        args["db_port"],
        args["db_name"],
        args["db_user"],
        args["db_password"],
        args["db_socket_opts"]
      )

    state = %{
      backoff:
        Backoff.new(
          backoff_min: 100,
          backoff_max: 120_000,
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
          backoff: backoff,
          conn: conn,
          db_host: db_host,
          db_port: db_port,
          db_name: db_name,
          db_user: db_user,
          db_pass: db_pass,
          db_socket_opts: socket_opts,
          slot_name: slot_name
        } = state
      ) do
    try do
      migrate_tenant(db_host, db_port, db_name, db_user, db_pass, socket_opts)
      Replications.prepare_replication(conn, slot_name)
    catch
      :error, error -> {:error, error}
    end
    |> case do
      {:ok, _} ->
        send(self(), :poll)
        {:noreply, state}

      {:error, error} ->
        Logger.error("Prepare replication error: #{inspect(error)}")
        {timeout, backoff} = Backoff.backoff(backoff)
        Process.sleep(timeout)
        {:noreply, %{state | backoff: backoff}, {:continue, :prepare_replication}}
    end
  end

  @impl true
  def handle_info(
        :poll,
        %{
          backoff: backoff,
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
        backoff = Backoff.reset(backoff)

        poll_ref =
          if rows_num > 0 do
            send(self(), :poll)
            nil
          else
            Process.send_after(self(), :poll, poll_interval_ms)
          end

        {:noreply, %{state | backoff: backoff, poll_ref: poll_ref}}

      {:error, reason} ->
        Logger.error("Error polling replication: #{inspect(reason, pretty: true)}")

        {timeout, backoff} = Backoff.backoff(backoff)
        Process.sleep(timeout)

        {:noreply, %{state | backoff: backoff}, {:continue, :prepare_replication}}
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

  def connect_db(host, port, name, user, pass, socket_opts) do
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

  def migrate_tenant(host, port, name, user, pass, socket_opts) do
    {host, port, name, user, pass} = decrypt_creds(host, port, name, user, pass)

    Repo.with_dynamic_repo(
      [
        hostname: host,
        port: port,
        database: name,
        password: pass,
        username: user,
        socket_opts: socket_opts
      ],
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
  end

  def decrypt_creds(host, port, name, user, pass) do
    secure_key = Application.get_env(:realtime, :db_enc_key)

    {
      decrypt!(host, secure_key),
      decrypt!(port, secure_key),
      decrypt!(name, secure_key),
      decrypt!(user, secure_key),
      decrypt!(pass, secure_key)
    }
  end
end
