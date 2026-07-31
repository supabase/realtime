defmodule RealtimeWeb.Dashboard.TenantMigrations do
  @moduledoc """
  Live Dashboard page to inspect tenant migrations state.

  Requires `pgdelta` on `$PATH`.

  Tenants are diffed against the catalog snapshot matching their own Postgres
  major version (falling back to the nearest older one).
  """
  use Phoenix.LiveDashboard.PageBuilder
  use Realtime.Logs

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.Nodes
  alias Realtime.Rpc
  alias Realtime.Tenants.Migrations

  @pgdelta_filter ~s"""
  {
    "and": [
      {"*/schema": "realtime"},
      {"not": {"table/is_partition": true}},
      {"not": {"and": [{"objectType": "rls_policy"}, {"operation": "drop"}]}},
      {"not": {"and": [{"table/schema": "realtime"}, {"table/name": "schema_migrations"}]}}
    ]
  }
  """
  @application_name "realtime_migrations"
  @query_timeout 60_000
  @pgdelta_timeout @query_timeout * 2
  @rpc_timeout @query_timeout * 3

  @impl true
  def menu_link(_, _), do: {:ok, "Tenant Migrations"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, reset_assigns(socket)}
  end

  @impl true
  def handle_params(%{"external_id" => ref}, _uri, socket) when ref != "" do
    ref = String.trim(ref)

    with %Tenant{} = tenant <- Api.get_tenant_by_external_id(ref),
         {:ok, settings} <- Database.from_tenant(tenant, @application_name, :stop),
         {:ok, schema_migrations, catalog_major_version} <- with_tenant_conn(settings, &fetch_tenant_state/1) do
      socket
      |> reset_assigns()
      |> assign(external_id: ref, tenant: tenant, schema_migrations: {:ok, schema_migrations})
      |> start_pgdelta(tenant, catalog_major_version)
      |> then(&{:noreply, &1})
    else
      nil ->
        {:noreply, assign_error(socket, ref, "Tenant not found")}

      {:error, reason} ->
        log_error("TenantMigrationsConnectFailed", reason)
        {:noreply, assign_error(socket, ref, "Failed to connect to tenant DB: #{inspect(reason)}")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, reset_assigns(socket)}
  end

  @impl true
  def handle_info(:pgdelta_tick, %{assigns: %{pgdelta_running: true}} = socket) do
    elapsed = System.monotonic_time(:millisecond) - socket.assigns.pgdelta_started_at

    socket
    |> assign(pgdelta_elapsed_ms: elapsed)
    |> schedule_tick()
    |> then(&{:noreply, &1})
  end

  def handle_info(
        {ref, {:rechecked, schema_migrations, pgdelta_result}},
        %{assigns: %{pgdelta_task: %Task{ref: ref}}} = socket
      ) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     assign(socket,
       schema_migrations: schema_migrations,
       pgdelta_result: pgdelta_result,
       pgdelta_running: false,
       pgdelta_task: nil
     )}
  end

  def handle_info({ref, pgdelta_result}, %{assigns: %{pgdelta_task: %Task{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, pgdelta_result: pgdelta_result, pgdelta_running: false, pgdelta_task: nil)}
  end

  def handle_info({ref, :ok}, %{assigns: %{apply_task: %Task{ref: ref}, tenant: %Tenant{} = tenant}} = socket) do
    Process.demonitor(ref, [:flush])
    socket = assign(socket, applying: false, apply_task: nil, error: nil)

    case Database.from_tenant(tenant, @application_name, :stop) do
      {:ok, settings} ->
        case socket.assigns.pgdelta_result do
          {:ok, %{status: :changes}} ->
            socket |> start_recheck(tenant, settings) |> then(&{:noreply, &1})

          _ ->
            schema_migrations = with_tenant_conn(settings, &fetch_schema_migrations/1)
            {:noreply, assign(socket, schema_migrations: schema_migrations)}
        end

      {:error, reason} ->
        {:noreply, assign(socket, error: "Applied, but re-check failed: #{inspect(reason)}")}
    end
  end

  def handle_info({ref, {:error, msg}}, %{assigns: %{apply_task: %Task{ref: ref}}} = socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, applying: false, apply_task: nil, error: msg)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{pgdelta_task: %Task{ref: ref}}} = socket) do
    log_error("TenantMigrationsPgDeltaCrash", inspect(reason))

    {:noreply,
     assign(socket,
       pgdelta_result: {:error, "pg-delta crashed: #{inspect(reason)}"},
       pgdelta_running: false,
       pgdelta_task: nil
     )}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{assigns: %{apply_task: %Task{ref: ref}}} = socket) do
    log_error("TenantMigrationsApplyCrash", inspect(reason))
    {:noreply, assign(socket, applying: false, apply_task: nil, error: "Apply crashed: #{inspect(reason)}")}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("lookup", %{"external_id" => ref}, socket) do
    ref = String.trim(ref)
    {:noreply, push_patch(socket, to: "/admin/dashboard/tenant_migrations?external_id=#{URI.encode(ref)}")}
  end

  @impl true
  def handle_event("apply", _params, socket) do
    %{tenant: %Tenant{} = tenant, pgdelta_result: pgdelta_result} = socket.assigns

    case pgdelta_result do
      {:ok, %{status: :changes, sql: sql}} -> {:noreply, start_apply(socket, tenant, sql)}
      {:ok, %{status: :no_changes}} -> {:noreply, start_apply(socket, tenant, nil)}
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="phx-dashboard-section">
      <h5 class="card-title">Tenant Migrations</h5>
      <p class="text-muted">
        Inspect a tenant's applied migrations and drift against the catalog schema snapshot.
      </p>

      <form phx-submit="lookup" class="mb-4 d-flex gap-2">
        <input
          type="text"
          name="external_id"
          value={@external_id}
          placeholder="Enter external_id"
          class="form-control w-auto"
          autocomplete="off"
          spellcheck="false"
        />
        <button type="submit" class="btn btn-primary" phx-disable-with="Loading...">Lookup</button>
      </form>

      <%= if @error do %>
        <p class="text-danger"><%= @error %></p>
      <% end %>

      <%= if @tenant do %>
        <h6 class="mt-4">realtime.schema_migrations</h6>
        <%= schema_migrations(@schema_migrations) %>

        <h6 class="mt-4">pg-delta plan vs catalog<%= if @catalog_major_version, do: " (PG#{@catalog_major_version})", else: "" %></h6>
        <div :if={@pgdelta_running} class="alert alert-info d-flex align-items-center" style="gap: 8px;">
          <div class="spinner-border spinner-border-sm" role="status"></div>
          <span>Processing... (<%= div(@pgdelta_elapsed_ms, 1000) %>s)</span>
        </div>
        <div :if={@applying} class="alert alert-info d-flex align-items-center" style="gap: 8px;">
          <div class="spinner-border spinner-border-sm" role="status"></div>
          <span>Applying plan to tenant database...</span>
        </div>
        <%= pgdelta_plan(@pgdelta_result, @schema_migrations, @applying or @pgdelta_running) %>
      <% end %>
    </div>
    """
  end

  defp reset_assigns(socket) do
    assign(socket,
      external_id: "",
      tenant: nil,
      schema_migrations: nil,
      pgdelta_result: nil,
      pgdelta_elapsed_ms: 0,
      pgdelta_running: false,
      pgdelta_started_at: nil,
      pgdelta_task: nil,
      applying: false,
      apply_task: nil,
      catalog_major_version: nil,
      error: nil
    )
  end

  defp assign_error(socket, ref, msg) do
    socket
    |> reset_assigns()
    |> assign(external_id: ref, error: msg)
  end

  defp schedule_tick(socket) do
    Process.send_after(self(), :pgdelta_tick, 1000)
    socket
  end

  defp fetch_tenant_state(conn) do
    major_version = fetch_major_version(conn)

    with {:ok, _} <- ensure_realtime_admin_role(conn),
         {:ok, _} <- ensure_schema_migrations(conn),
         {:ok, schema_migrations} <- fetch_schema_migrations(conn) do
      {:ok, schema_migrations, major_version}
    end
  end

  defp start_pgdelta(socket, %Tenant{} = tenant, catalog_major_version) do
    task = Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn -> run_pgdelta(tenant, catalog_major_version) end)
    running_pgdelta(socket, task, catalog_major_version)
  end

  defp start_recheck(socket, %Tenant{} = tenant, %Database{} = settings) do
    task =
      Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn ->
        {:rechecked, with_tenant_conn(settings, &fetch_schema_migrations/1),
         run_pgdelta(tenant, socket.assigns.catalog_major_version)}
      end)

    socket
    |> assign(schema_migrations: nil)
    |> running_pgdelta(task, socket.assigns.catalog_major_version)
  end

  defp running_pgdelta(socket, task, catalog_major_version) do
    socket
    |> assign(
      catalog_major_version: catalog_major_version,
      pgdelta_running: true,
      pgdelta_elapsed_ms: 0,
      pgdelta_started_at: System.monotonic_time(:millisecond),
      pgdelta_task: task
    )
    |> schedule_tick()
  end

  defp start_apply(socket, %Tenant{} = tenant, sql) do
    task = Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn -> apply_pgdelta(tenant, sql) end)
    assign(socket, applying: true, apply_task: task, error: nil)
  end

  defp migrations_progress(schema_migrations) do
    total = length(Migrations.migrations())

    applied =
      case schema_migrations do
        {:ok, rows} -> length(rows)
        _ -> total
      end

    {applied, total}
  end

  defp schema_migrations(nil) do
    assigns = %{}
    ~H""
  end

  defp schema_migrations({:error, msg}) do
    assigns = %{msg: msg}

    ~H"""
    <p class="text-danger"><%= @msg %></p>
    """
  end

  defp schema_migrations({:ok, rows}) do
    assigns = %{rows: rows}

    ~H"""
    <p class="text-muted small mb-2"><strong><%= length(@rows) %></strong> row(s)</p>
    <div style="max-height: 400px; overflow: auto; border: 1px solid #dee2e6; border-radius: 6px;">
      <table style="border-collapse: separate; border-spacing: 0; font-size: 0.8rem; margin: 0; width: 100%;">
        <thead>
          <tr>
            <th style="position: sticky; top: 0; z-index: 1; background: #1a1a2e; color: #e6edf3; padding: 8px 12px; text-align: left; font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace; font-weight: 600; border-bottom: 2px solid #30363d;">
              version
            </th>
            <th style="position: sticky; top: 0; z-index: 1; background: #1a1a2e; color: #e6edf3; padding: 8px 12px; text-align: left; font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace; font-weight: 600; border-bottom: 2px solid #30363d;">
              inserted_at
            </th>
          </tr>
        </thead>
        <tbody>
          <%= for {[version, inserted_at], idx} <- Enum.with_index(@rows) do %>
            <tr style={"background: #{if rem(idx, 2) == 0, do: "#ffffff", else: "#f8f9fa"};"}>
              <td style="padding: 6px 12px; font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace; border-bottom: 1px solid #e9ecef; color: #212529;">
                <%= version %>
              </td>
              <td style="padding: 6px 12px; font-family: 'SF Mono', Menlo, Monaco, Consolas, monospace; border-bottom: 1px solid #e9ecef; color: #495057;">
                <%= inserted_at %>
              </td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </div>
    """
  end

  defp pgdelta_plan(nil, _schema_migrations, _apply_disabled) do
    assigns = %{}
    ~H""
  end

  defp pgdelta_plan({:error, msg}, _schema_migrations, _apply_disabled) do
    assigns = %{msg: msg}

    ~H"""
    <div class="alert alert-danger">
      <strong>Error:</strong>
      <pre class="mb-0 mt-2" style="white-space: pre-wrap; word-break: break-word;"><%= @msg %></pre>
    </div>
    """
  end

  defp pgdelta_plan({:ok, %{status: :no_changes}}, schema_migrations, apply_disabled) do
    {applied, total} = migrations_progress(schema_migrations)
    assigns = %{behind: applied < total, applied: applied, total: total, apply_disabled: apply_disabled}

    ~H"""
    <div :if={@behind}>
      <div class="alert alert-warning">
        No schema drift, but realtime.schema_migrations has <%= @applied %> of <%= @total %> versions recorded.
        Apply records the missing version(s) and sets tenants.migrations_ran to <%= @total %>.
      </div>
      <div class="d-flex justify-content-end mt-3">
        <button type="button" class="btn btn-primary" phx-click="apply" phx-disable-with="Applying..." disabled={@apply_disabled}>
          Apply
        </button>
      </div>
    </div>
    <div :if={not @behind} class="alert alert-success mb-0">
      No drift detected. Tenant schema matches the catalog.
    </div>
    """
  end

  defp pgdelta_plan({:ok, %{status: :changes, sql: sql}}, _schema_migrations, apply_disabled) do
    assigns = %{sql: sql, apply_disabled: apply_disabled}

    ~H"""
    <div class="alert alert-warning">
      <strong>Drift detected between tenant and catalog.</strong>
      The SQL below is reconciliation plan generated by pg-delta and it may contain errors and/or destructive statements.
      Review every statement before running it.
    </div>
    <div style="position: relative;">
      <button
        type="button"
        title="Copy SQL"
        class="btn btn-sm btn-secondary"
        onclick={"
          const btn = this;
          const code = btn.parentElement.querySelector('code').innerText;
          navigator.clipboard.writeText(code).then(() => {
            const prev = btn.innerText;
            btn.innerText = 'Copied';
            btn.disabled = true;
            setTimeout(() => { btn.innerText = prev; btn.disabled = false; }, 1200);
          });
        "}
        style="position: absolute; top: 8px; right: 8px; z-index: 2;"
      >Copy</button>
      <pre style="background: #0d1117; color: #e6edf3; padding: 16px; padding-right: 64px; border-radius: 6px; overflow: auto; max-height: 500px; margin: 0;"><code class="language-sql"><%= @sql %></code></pre>
    </div>
    <div class="d-flex justify-content-end mt-3">
      <button
        type="button"
        class="btn btn-danger"
        phx-click="apply"
        phx-disable-with="Applying..."
        disabled={@apply_disabled}
        data-confirm="Apply this SQL plan to the tenant database? This may include destructive statements and is irreversible."
      >
        Apply
      </button>
    </div>
    """
  end

  defp insert_versions(conn, versions) do
    insert = """
    INSERT INTO realtime.schema_migrations (version, inserted_at)
    SELECT unnest($1::bigint[]), NOW()
    ON CONFLICT (version) DO NOTHING
    """

    case Postgrex.query(conn, insert, [versions], timeout: @query_timeout) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  defp fetch_schema_migrations(conn) do
    schema_migrations_query = "SELECT version, inserted_at FROM realtime.schema_migrations ORDER BY version DESC"

    case Postgrex.query(conn, schema_migrations_query, [], timeout: @query_timeout) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [v, ts] -> [to_string(v), format_ts(ts)] end)}

      {:error, %{postgres: %{message: message}}} ->
        log_error("TenantMigrationsSchemaMigrationsQueryFailed", message)
        {:error, message}

      {:error, reason} ->
        log_error("TenantMigrationsSchemaMigrationsQueryFailed", reason)
        {:error, inspect(reason)}
    end
  end

  defp fetch_major_version(conn) do
    server_major_version_query = "SELECT current_setting('server_version_num')::int / 10000"
    {:ok, %{rows: [[version]]}} = Postgrex.query(conn, server_major_version_query, [])
    if version >= 17, do: 17, else: 15
  end

  defp ensure_schema_migrations(conn) do
    Postgrex.query(
      conn,
      "CREATE TABLE IF NOT EXISTS realtime.schema_migrations (version bigint PRIMARY KEY, inserted_at timestamp)",
      []
    )
  end

  defp ensure_realtime_admin_role(conn) do
    case Postgrex.query(conn, "SELECT 1 FROM pg_roles WHERE rolname = 'supabase_realtime_admin'", []) do
      {:ok, %{num_rows: 0}} -> Postgrex.query(conn, "CREATE ROLE supabase_realtime_admin", [])
      result -> result
    end
  end

  defp format_ts(%NaiveDateTime{} = t), do: NaiveDateTime.to_string(t)
  defp format_ts(%DateTime{} = t), do: DateTime.to_string(t)
  defp format_ts(other), do: to_string(other)

  @doc false
  def postgres_url(%Database{} = db) do
    sslmode = if db.ssl, do: "require", else: "disable"

    hostname =
      case :inet.parse_ipv6strict_address(String.to_charlist(db.hostname)) do
        {:ok, _} -> "[#{db.hostname}]"
        _ -> db.hostname
      end

    IO.iodata_to_binary([
      "postgresql://",
      URI.encode_www_form(db.username),
      ":",
      URI.encode_www_form(db.password),
      "@",
      hostname,
      ":",
      Integer.to_string(db.port),
      "/",
      URI.encode_www_form(db.database),
      "?sslmode=",
      sslmode
    ])
  end

  @doc false
  # Used for debugging
  def pgdelta_filter, do: @pgdelta_filter

  defp catalog_path(major) do
    Application.app_dir(:realtime, "priv/repo/tenant_db_catalog_#{major}.json")
  end

  @doc false
  def run_pgdelta(%Tenant{external_id: external_id} = tenant, catalog_major_version) do
    with {:ok, node, _region} <- Nodes.get_node_for_tenant(tenant),
         {:ok, _} = result <-
           Rpc.enhanced_call(node, __MODULE__, :run_pgdelta_tenant, [tenant, catalog_major_version],
             timeout: @rpc_timeout,
             tenant_id: external_id
           ) do
      result
    else
      {:error, :rpc_error, reason} -> {:error, "pg-delta RPC failed: #{inspect(reason)}"}
      {:error, _} = err -> err
    end
  end

  def run_pgdelta(%Database{} = settings, catalog_major_version) do
    case System.find_executable("pgdelta") do
      nil ->
        log_error("TenantMigrationsPgDeltaMissing", "pgdelta not found on PATH")
        {:error, "pgdelta not found on PATH"}

      path ->
        catalog = catalog_path(catalog_major_version)

        args = [
          "plan",
          "--source",
          postgres_url(settings),
          "--target",
          catalog,
          "--filter",
          pgdelta_filter(),
          "--format",
          "sql"
        ]

        env = [
          {~c"PGDELTA_CONNECTION_TIMEOUT_MS", ~c"#{@query_timeout}"},
          {~c"PGDELTA_CONNECT_TIMEOUT_MS", ~c"#{@query_timeout}"}
        ]

        case run_pgdelta_cmd(path, args, env) do
          {output, 0} ->
            {:ok, %{status: :no_changes, sql: output}}

          {output, 2} ->
            {:ok, %{status: :changes, sql: output}}

          :timeout ->
            log_error("TenantMigrationsPgDeltaTimeout", "killed after #{@pgdelta_timeout}ms")
            {:error, "pg-delta timed out after #{div(@pgdelta_timeout, 1000)}s"}

          {output, code} ->
            log_error("TenantMigrationsPgDeltaNonZeroExit", "exit #{code}: #{output}")
            {:error, "pg-delta exited #{code}:\n#{output}"}
        end
    end
  end

  defp run_pgdelta_cmd(path, args, env) do
    port =
      Port.open({:spawn_executable, path}, [:binary, :exit_status, :stderr_to_stdout, args: args, env: env])

    collect_pgdelta(port, [])
  end

  defp collect_pgdelta(port, acc) do
    receive do
      {^port, {:data, data}} ->
        collect_pgdelta(port, [acc | data])

      {^port, {:exit_status, status}} ->
        {IO.iodata_to_binary(acc), status}
    after
      @pgdelta_timeout ->
        if Port.info(port), do: Port.close(port)
        :timeout
    end
  end

  @doc false
  def run_pgdelta_tenant(%Tenant{} = tenant, catalog_major_version) do
    with {:ok, settings} <- Database.from_tenant(tenant, @application_name, :stop) do
      run_pgdelta(settings, catalog_major_version)
    end
  end

  @doc false
  def apply_pgdelta(%Tenant{external_id: external_id} = tenant, sql) do
    versions = Enum.map(Migrations.migrations(), fn {v, _mod} -> v end)
    total = length(versions)

    with {:ok, settings} <- Database.from_tenant(tenant, @application_name, :stop),
         :ok <- with_tenant_conn(settings, &apply_plan(&1, sql, versions)),
         {:ok, _} <- Api.update_migrations_ran(external_id, total) do
      :ok
    else
      {:error, %{postgres: %{message: message}}} ->
        log_error("TenantMigrationsApplyFailed", message)
        {:error, "Apply failed: #{message}"}

      {:error, reason} ->
        log_error("TenantMigrationsApplyFailed", reason)
        {:error, "Apply failed: #{inspect(reason)}"}
    end
  end

  defp apply_plan(conn, nil, versions), do: insert_versions(conn, versions)

  defp apply_plan(conn, sql, versions) do
    with {:ok, _} <- Postgrex.query(conn, sql, [], query_type: :text, timeout: @query_timeout) do
      insert_versions(conn, versions)
    end
  end

  defp with_tenant_conn(%Database{} = settings, fun) do
    case Database.connect_db(%{settings | pool_size: 1}) do
      {:ok, conn} ->
        result = fun.(conn)
        GenServer.stop(conn)
        result

      {:error, _} = err ->
        err
    end
  end
end
