defmodule Realtime.Repo.RegionAdapter do
  @moduledoc """
  Adapter that routes calls to the appropriate node based on the region.
  """
  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Migration
  @behaviour Ecto.Adapter.Queryable
  @behaviour Ecto.Adapter.Schema
  @behaviour Ecto.Adapter.Transaction
  @behaviour Ecto.Adapters.SQL.Connection

  alias Realtime.GenRpc

  @impl Ecto.Adapter
  defmacro __before_compile__(_env) do
    quote do
    end
  end

  @impl Ecto.Adapter
  def init(opts) do
    repo = Keyword.get(opts, :repo, Realtime.Repo)
    telemetry_prefix = Keyword.get(opts, :telemetry_prefix, [:realtime, :repo])
    opts = Keyword.put_new(opts, :repo, repo) |> Keyword.put_new(:telemetry_prefix, telemetry_prefix)

    {:ok, child_spec, adapter_meta} = Ecto.Adapters.Postgres.init(opts)
    adapter_meta = Map.put(adapter_meta, :remote, target_node())

    {:ok, child_spec, adapter_meta}
  end

  defp target_node() do
    region = Application.get_env(:realtime, :region)
    master_region = Application.get_env(:realtime, :master_region, region)

    with false <- master_region == region,
         {:ok, node} <- Realtime.Nodes.node_from_region(master_region, node()) do
      node
    else
      _ -> node()
    end
  end

  defp run_on_target(target_node, function, args) when target_node == node() do
    apply(Ecto.Adapters.Postgres, function, args)
  end

  defp run_on_target(target_node, function, args) do
    GenRpc.call(target_node, __MODULE__, function, args, [])
  end

  @impl Ecto.Adapter
  def ensure_all_started(config, type) do
    target_node = target_node()
    run_on_target(target_node, :ensure_all_started, [config, type])
  end

  @impl Ecto.Adapter
  def checked_out?(adapter_meta) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.checked_out?(adapter_meta),
      else: raise("checked_out? is not supported on remote nodes")
  end

  @impl Ecto.Adapter
  def checkout(adapter_meta, config, function) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.checkout(adapter_meta, config, function),
      else: raise("checkout is not supported on remote nodes")
  end

  @impl Ecto.Adapter
  def dumpers(primitive_type, ecto_type) do
    target_node = target_node()
    run_on_target(target_node, :dumpers, [primitive_type, ecto_type])
  end

  @impl Ecto.Adapter
  def loaders(primitive_type, ecto_type) do
    target_node = target_node()
    run_on_target(target_node, :loaders, [primitive_type, ecto_type])
  end

  @impl Ecto.Adapter.Queryable
  def prepare(operation, query) do
    target_node = target_node()
    run_on_target(target_node, :prepare, [operation, query])
  end

  @impl Ecto.Adapter.Queryable
  def execute(adapter_meta, query_meta, query, params, opts) do
    target_node = target_node()
    run_on_target(target_node, :execute, [adapter_meta, query_meta, query, params, opts])
  end

  @impl Ecto.Adapter.Queryable
  def stream(adapter_meta, query_meta, query, params, opts) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.stream(adapter_meta, query_meta, query, params, opts),
      else: raise("stream is not supported on remote nodes")
  end

  @impl Ecto.Adapter.Schema
  def autogenerate(field_type) do
    target_node = target_node()
    run_on_target(target_node, :autogenerate, [field_type])
  end

  @impl Ecto.Adapter.Schema
  def insert_all(adapter_meta, schema_meta, header, rows, on_conflict, returning, placeholders, opts) do
    target_node = target_node()

    run_on_target(target_node, :insert_all, [
      adapter_meta,
      schema_meta,
      header,
      rows,
      on_conflict,
      returning,
      placeholders,
      opts
    ])
  end

  @impl Ecto.Adapter.Schema
  def insert(adapter_meta, schema_meta, params, on_conflict, returning, opts) do
    target_node = target_node()
    run_on_target(target_node, :insert, [adapter_meta, schema_meta, params, on_conflict, returning, opts])
  end

  @impl Ecto.Adapter.Schema
  def update(adapter_meta, schema_meta, fields, params, returning, opts) do
    target_node = target_node()
    run_on_target(target_node, :update, [adapter_meta, schema_meta, fields, params, returning, opts])
  end

  @impl Ecto.Adapter.Schema
  def delete(adapter_meta, schema_meta, params, returning, opts) do
    target_node = target_node()
    run_on_target(target_node, :delete, [adapter_meta, schema_meta, params, returning, opts])
  end

  @impl Ecto.Adapter.Transaction
  def transaction(adapter_meta, opts, fun) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.transaction(adapter_meta, opts, fun),
      else: raise("transaction is not supported on remote nodes")
  end

  @impl Ecto.Adapter.Transaction
  def in_transaction?(adapter_meta) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.in_transaction?(adapter_meta),
      else: raise("in_transaction? is not supported on remote nodes")
  end

  @impl Ecto.Adapter.Transaction
  @spec rollback(Ecto.Adapter.adapter_meta(), term()) :: no_return()
  def rollback(adapter_meta, value) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.rollback(adapter_meta, value),
      else: raise("rollback is not supported on remote nodes")
  end

  @impl Ecto.Adapter.Storage
  def storage_up(opts) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.storage_up(opts),
      else: raise("storage_up is not supported on remote nodes")
  end

  @impl Ecto.Adapter.Storage
  def storage_down(opts) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.storage_down(opts),
      else: raise("storage_down is not supported on remote nodes")
  end

  @impl Ecto.Adapter.Storage
  def storage_status(opts) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.storage_status(opts),
      else: raise("storage_status is not supported on remote nodes")
  end

  @impl Ecto.Adapters.SQL.Connection
  def child_spec(opts) do
    target_node = target_node()
    run_on_target(target_node, :child_spec, [opts])
  end

  @impl Ecto.Adapters.SQL.Connection
  def prepare_execute(conn, name, statement, params, opts) do
    target_node = target_node()
    run_on_target(target_node, :prepare_execute, [conn, name, statement, params, opts])
  end

  @impl Ecto.Adapters.SQL.Connection
  def execute(conn, cached, params, opts) do
    target_node = target_node()
    run_on_target(target_node, :execute, [conn, cached, params, opts])
  end

  @impl Ecto.Adapters.SQL.Connection
  def query(conn, statement, params, opts) do
    target_node = target_node()
    run_on_target(target_node, :query, [conn, statement, params, opts])
  end

  @impl Ecto.Adapters.SQL.Connection
  @spec query_many(DBConnection.conn(), iodata(), Ecto.Adapters.SQL.query_params(), Keyword.t()) ::
          no_return()
  def query_many(conn, statement, params, opts) do
    target_node = target_node()
    run_on_target(target_node, :query_many, [conn, statement, params, opts])
  end

  @impl Ecto.Adapters.SQL.Connection
  def stream(conn, statement, params, opts) do
    target_node = target_node()
    run_on_target(target_node, :stream, [conn, statement, params, opts])
  end

  @impl Ecto.Adapters.SQL.Connection
  def to_constraints(exception, opts) do
    target_node = target_node()
    run_on_target(target_node, :to_constraints, [exception, opts])
  end

  @impl Ecto.Adapters.SQL.Connection
  def all(query, as_prefix \\ []) do
    target_node = target_node()
    run_on_target(target_node, :all, [query, as_prefix])
  end

  @impl Ecto.Adapters.SQL.Connection
  def update_all(query, prefix \\ nil) do
    target_node = target_node()
    run_on_target(target_node, :update_all, [query, prefix])
  end

  @impl Ecto.Adapters.SQL.Connection
  def delete_all(query) do
    target_node = target_node()
    run_on_target(target_node, :delete_all, [query])
  end

  @impl Ecto.Adapters.SQL.Connection
  def insert(prefix, table, header, rows, on_conflict, returning, placeholders) do
    target_node = target_node()
    run_on_target(target_node, :insert, [prefix, table, header, rows, on_conflict, returning, placeholders])
  end

  @impl Ecto.Adapters.SQL.Connection
  def update(prefix, table, fields, filters, returning) do
    target_node = target_node()
    run_on_target(target_node, :update, [prefix, table, fields, filters, returning])
  end

  @impl Ecto.Adapters.SQL.Connection
  def delete(prefix, table, filters, returning) do
    target_node = target_node()
    run_on_target(target_node, :delete, [prefix, table, filters, returning])
  end

  @impl Ecto.Adapters.SQL.Connection
  def explain_query(conn, query, params, opts) do
    target_node = target_node()
    run_on_target(target_node, :explain_query, [conn, query, params, opts])
  end

  @impl Ecto.Adapters.SQL.Connection
  def execute_ddl(command) do
    target_node = target_node()
    run_on_target(target_node, :execute_ddl, [command])
  end

  @impl Ecto.Adapters.SQL.Connection
  def ddl_logs(result) do
    target_node = target_node()
    run_on_target(target_node, :ddl_logs, [result])
  end

  @impl Ecto.Adapters.SQL.Connection
  def table_exists_query(table) do
    target_node = target_node()
    run_on_target(target_node, :table_exists_query, [table])
  end

  @impl Ecto.Adapter.Migration
  def execute_ddl(meta, definition, opts) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.execute_ddl(meta, definition, opts),
      else: raise("execute_ddl is not supported on remote nodes")
  end

  @impl Ecto.Adapter.Migration
  def supports_ddl_transaction? do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.supports_ddl_transaction?(),
      else: raise("supports_ddl_transaction? is not supported on remote nodes")
  end

  @impl Ecto.Adapter.Migration
  def lock_for_migrations(meta, opts, fun) do
    if target_node() == node(),
      do: Ecto.Adapters.Postgres.lock_for_migrations(meta, opts, fun),
      else: raise("lock_for_migrations is not supported on remote nodes")
  end
end
