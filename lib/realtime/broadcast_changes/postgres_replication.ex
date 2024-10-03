defmodule Realtime.BroadcastChanges.PostgresReplication do
  @moduledoc """
  PostgresReplication is a module that provides a way to stream data from a PostgreSQL database using logical replication.

  ## Struct parameters
  * `connection_opts` - The connection options to connect to the database.
  * `table` - The table to replicate. If `:all` is passed, it will replicate all tables.
  * `schema` - The schema of the table to replicate. If not provided, it will use the `public` schema. If `:all` is passed, this option is ignored.
  * `opts` - The options to pass to this module
  * `step` - The current step of the replication process
  * `publication_name` - The name of the publication to create. If not provided, it will use the schema and table name.
  * `replication_slot_name` - The name of the replication slot to create. If not provided, it will use the schema and table name.
  * `output_plugin` - The output plugin to use. Default is `pgoutput`.
  * `proto_version` - The protocol version to use. Default is `1`.
  * `handler_module` - The module that will handle the data received from the replication stream.
  * `metadata` - The metadata to pass to the handler module.

  """
  use Postgrex.ReplicationConnection
  require Logger

  defmodule Handler do
    @type t :: module()
    @doc """
    The `call/2` callback is called by the `PostgresReplication` module to send messages to the parent process. It also sends back to the server connection a message in return if the user wants to.

    ## Parameters
      * `message` - The message to be sent to the parent process.
      * `metadata` - The metadata to be passed to the handler module.

    ## Returns
      * `{:reply, [term]}` - The message to be sent to server connection. Read more in Realtime.Adapters.Postgres.Protocol
      * `:noreply` - No message is sent back to the server.
    """
    @callback call(any, map()) :: {:reply, [term]} | :noreply
  end

  @derive {Inspect, except: [:connection_opts]}

  @default_opts [
    auto_reconnect: false,
    sync_connect: true
  ]
  @type t :: %__MODULE__{
          connection_opts: Keyword.t(),
          table: String.t(),
          schema: String.t(),
          opts: Keyword.t(),
          step:
            :disconnected
            | :check_replication_slot
            | :create_publication
            | :check_publication
            | :create_slot
            | :start_replication_slot
            | :streaming,
          publication_name: String.t(),
          replication_slot_name: String.t(),
          output_plugin: String.t(),
          proto_version: integer(),
          handler_module: Handler.t(),
          metadata: map()
        }
  defstruct connection_opts: nil,
            table: nil,
            schema: "public",
            opts: [],
            step: :disconnected,
            publication_name: nil,
            replication_slot_name: nil,
            output_plugin: "pgoutput",
            proto_version: 1,
            handler_module: nil,
            metadata: %{}

  def start_link(%__MODULE__{opts: opts, connection_opts: connection_opts} = attrs) do
    opts = @default_opts |> Keyword.merge(opts) |> Keyword.merge(connection_opts)

    case Postgrex.ReplicationConnection.start_link(__MODULE__, attrs, opts) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, {:bad_return_from_init, {:stop, reason, _}}} -> {:error, reason}
      {:error, {:case_clause, {:disconnect, reason, _}}} -> {:error, reason}
      {:error, error} -> {:disconnect, error}
    end
  end

  @impl true
  def init(%__MODULE__{} = attrs) do
    Logger.info("Initializing connection with the status: #{inspect(attrs, pretty: true)}")

    publication_name = publication_name(attrs)
    replication_slot_name = replication_slot_name(attrs)

    state =
      %{
        attrs
        | step: :disconnected,
          publication_name: publication_name,
          replication_slot_name: replication_slot_name
      }

    {:ok, state}
  end

  @impl true
  def handle_connect(state) do
    replication_slot_name = replication_slot_name(state)
    Logger.info("Checking if replication slot #{replication_slot_name} exists")

    query =
      "SELECT * FROM pg_replication_slots WHERE slot_name = '#{replication_slot_name}'"

    {:query, query, %{state | step: :check_replication_slot}}
  end

  @impl true
  def handle_result(
        [%Postgrex.Result{num_rows: 1}],
        %__MODULE__{step: :check_replication_slot} = state
      ) do
    {:disconnect, "Temporary Replication slot already exists and in use", state}
  end

  def handle_result(
        [%Postgrex.Result{num_rows: 0}],
        %__MODULE__{step: :check_replication_slot} = state
      ) do
    %__MODULE__{
      output_plugin: output_plugin,
      replication_slot_name: replication_slot_name,
      step: :check_replication_slot
    } = state

    Logger.info("Create replication slot #{replication_slot_name} using plugin #{output_plugin}")

    query =
      "CREATE_REPLICATION_SLOT #{replication_slot_name} TEMPORARY LOGICAL #{output_plugin} NOEXPORT_SNAPSHOT"

    {:query, query, %{state | step: :check_publication}}
  end

  def handle_result(
        [%Postgrex.Result{}],
        %__MODULE__{step: :check_publication} = state
      ) do
    %__MODULE__{table: table, schema: schema, publication_name: publication_name} = state

    Logger.info("Check publication #{publication_name} for table #{schema}.#{table} exists")
    query = "SELECT * FROM pg_publication WHERE pubname = '#{publication_name}'"

    {:query, query, %{state | step: :create_publication}}
  end

  def handle_result(
        [%Postgrex.Result{num_rows: 0}],
        %__MODULE__{step: :create_publication, table: :all} = state
      ) do
    %{publication_name: publication_name} = state
    Logger.info("Create publication #{publication_name} for all tables")

    query =
      "CREATE PUBLICATION #{publication_name} FOR ALL TABLES"

    {:query, query, %{state | step: :start_replication_slot}}
  end

  def handle_result(
        [%Postgrex.Result{num_rows: 0}],
        %__MODULE__{step: :create_publication} = state
      ) do
    %__MODULE__{
      table: table,
      schema: schema,
      publication_name: publication_name
    } = state

    Logger.info("Create publication #{publication_name} for table #{schema}.#{table}")

    query =
      "CREATE PUBLICATION #{publication_name} FOR TABLE #{schema}.#{table}"

    {:query, query, %{state | step: :start_replication_slot}}
  end

  def handle_result(
        [%Postgrex.Result{num_rows: 1}],
        %__MODULE__{step: :create_publication} = state
      ) do
    {:query, "SELECT 1", %{state | step: :start_replication_slot}}
  end

  @impl true
  def handle_result(
        [%Postgrex.Result{}],
        %__MODULE__{step: :start_replication_slot} = state
      ) do
    %__MODULE__{
      proto_version: proto_version,
      replication_slot_name: replication_slot_name,
      publication_name: publication_name
    } = state

    Logger.info(
      "Starting stream replication for slot #{replication_slot_name} using publication #{publication_name} and protocol version #{proto_version}"
    )

    query =
      "START_REPLICATION SLOT #{replication_slot_name} LOGICAL 0/0 (proto_version '#{proto_version}', publication_names '#{publication_name}')"

    {:stream, query, [], %{state | step: :streaming}}
  end

  def handle_result(%Postgrex.Error{postgres: %{message: message}}, _state) do
    {:disconnect, "Error starting replication: #{message}"}
  end

  @impl true
  def handle_disconnect(state) do
    Logger.error("Disconnected from the server: #{inspect(state, pretty: true)}")

    {:noreply, %{state | step: :disconnected}}
  end

  @impl true
  def handle_data(data, state) do
    %__MODULE__{handler_module: handler_module, metadata: metadata} = state

    case handler_module.call(data, metadata) do
      {:reply, messages} -> {:noreply, messages, state}
      :noreply -> {:noreply, [], state}
      :shutdown -> {:disconnect, :handler_shutdown}
    end
  end

  def publication_name(%__MODULE__{publication_name: nil, table: :all}) do
    "all_table_publication"
  end

  def publication_name(%__MODULE__{publication_name: nil, table: table, schema: schema}) do
    "#{schema}_#{table}_publication"
  end

  def publication_name(%__MODULE__{publication_name: publication_name}) do
    publication_name
  end

  def replication_slot_name(%__MODULE__{replication_slot_name: nil, table: :all}) do
    "all_table_slot"
  end

  def replication_slot_name(%__MODULE__{replication_slot_name: nil, table: table, schema: schema}) do
    "#{schema}_#{table}_replication_slot"
  end

  def replication_slot_name(%__MODULE__{replication_slot_name: replication_slot_name}) do
    replication_slot_name
  end
end
