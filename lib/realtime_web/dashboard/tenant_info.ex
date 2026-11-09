defmodule RealtimeWeb.Dashboard.TenantInfo do
  @moduledoc """
  Live Dashboard page to inspect tenant and extension information by external_id.
  Secrets (jwt_secret and encrypted extension fields) are never displayed.

  It also reads, in a read-only transaction, who owns the realtime objects and who may execute
  the realtime functions in the tenant database, so a privilege problem can be diagnosed without
  SQL access to it.
  """
  use Phoenix.LiveDashboard.PageBuilder
  use Realtime.Logs

  alias Extensions.PostgresCdcRls
  alias Phoenix.LiveView.JS
  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database
  alias Realtime.Nodes
  alias Realtime.Tenants.Connect
  alias Realtime.UsersCounter

  @application_name "realtime_dashboard_tenant_info"
  @cdc_rls_stop_timeout 5_000
  @privileges_statement_timeout 5_000
  @database_info_timeout 15_000

  @empty_assigns [pg_version: nil, privileges: nil, runtime: nil, error: nil, action_msg: nil]

  @impl true
  def menu_link(_, _), do: {:ok, "Tenant Info"}

  @impl true
  def mount(_params, _, socket) do
    {:ok, assign(socket, [external_id: "", tenant: nil] ++ @empty_assigns)}
  end

  @impl true
  def handle_params(%{"external_id" => ref}, _uri, socket) when ref != "" do
    ref = String.trim(ref)

    case Api.get_tenant_by_external_id(ref) do
      nil ->
        {:noreply,
         assign(socket, [external_id: ref, tenant: nil] ++ Keyword.put(@empty_assigns, :error, "Tenant not found"))}

      %Tenant{} = tenant ->
        {pg_version, privileges} = fetch_database_info(tenant)

        {:noreply,
         assign(socket,
           external_id: ref,
           tenant: prepare_tenant(tenant),
           pg_version: pg_version,
           privileges: privileges,
           runtime: runtime_info(ref),
           error: nil,
           action_msg: nil
         )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, [external_id: "", tenant: nil] ++ @empty_assigns)}
  end

  @impl true
  def handle_event("lookup", %{"external_id" => ref}, socket) do
    ref = String.trim(ref)
    {:noreply, push_patch(socket, to: "/admin/dashboard/tenant_info?external_id=#{URI.encode(ref)}")}
  end

  def handle_event("shutdown_connect", _params, %{assigns: %{external_id: ref}} = socket) when ref != "" do
    Connect.shutdown(ref)
    {:noreply, assign(socket, action_msg: "Attempting to shutdown Connect for #{ref}...")}
  end

  def handle_event("shutdown_cdc_rls", _params, %{assigns: %{external_id: ref}} = socket) when ref != "" do
    Task.Supervisor.start_child(Realtime.TaskSupervisor, fn ->
      PostgresCdcRls.handle_stop(ref, @cdc_rls_stop_timeout)
    end)

    {:noreply, assign(socket, action_msg: "Attempting to shutdown Postgres Replication (CDC RLS) for #{ref}...")}
  end

  @impl true
  # Auto-refresh (the dashboard's "refresh every" selector) only recomputes the
  # cheap runtime info. pg_version and privileges are intentionally not refreshed
  # as they open a database connection.
  def handle_refresh(socket) do
    case socket.assigns do
      %{external_id: ref, tenant: %Tenant{}} when ref != "" ->
        {:noreply, assign(socket, runtime: runtime_info(ref))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="phx-dashboard-section">
      <h5 class="card-title">Tenant Info</h5>

      <form phx-submit="lookup" class="mb-4 d-flex gap-2">
        <input
          type="text"
          name="external_id"
          value={@external_id}
          placeholder="Enter external_id"
          class="form-control w-auto"
          autocomplete="off"
        />
        <button type="submit" class="btn btn-primary">Lookup</button>
      </form>

      <%= if @error do %>
        <p class="text-danger"><%= @error %></p>
      <% end %>

      <%= if @action_msg do %>
        <p class="text-success"><%= @action_msg %></p>
      <% end %>

      <%= if @tenant do %>
        <div class="card mb-4">
          <div class="card-header"><strong>Tenant</strong></div>
          <div class="card-body p-0">
            <table class="table table-hover mb-0">
              <tbody>
                <tr><td>external_id</td><td><%= @tenant.external_id %></td></tr>
                <tr><td>name</td><td><%= @tenant.name %></td></tr>
                <tr><td>suspend</td><td><%= @tenant.suspend %></td></tr>
                <tr><td>private_only</td><td><%= @tenant.private_only %></td></tr>
                <tr><td>presence_enabled</td><td><%= @tenant.presence_enabled %></td></tr>
                <tr><td>postgres_cdc_default</td><td><%= @tenant.postgres_cdc_default %></td></tr>
                <tr><td>broadcast_adapter</td><td><%= @tenant.broadcast_adapter %></td></tr>
                <tr><td>max_concurrent_users</td><td><%= @tenant.max_concurrent_users %></td></tr>
                <tr><td>max_events_per_second</td><td><%= @tenant.max_events_per_second %></td></tr>
                <tr><td>max_bytes_per_second</td><td><%= @tenant.max_bytes_per_second %></td></tr>
                <tr><td>max_channels_per_client</td><td><%= @tenant.max_channels_per_client %></td></tr>
                <tr><td>max_joins_per_second</td><td><%= @tenant.max_joins_per_second %></td></tr>
                <tr><td>max_presence_events_per_second</td><td><%= @tenant.max_presence_events_per_second %></td></tr>
                <tr><td>max_payload_size_in_kb</td><td><%= @tenant.max_payload_size_in_kb %></td></tr>
                <tr><td>max_client_presence_events_per_window</td><td><%= @tenant.max_client_presence_events_per_window %></td></tr>
                <tr><td>client_presence_window_ms</td><td><%= @tenant.client_presence_window_ms %></td></tr>
                <tr><td>migrations_ran</td><td><%= @tenant.migrations_ran %></td></tr>
                <tr><td>inserted_at</td><td><%= @tenant.inserted_at %></td></tr>
                <tr><td>updated_at</td><td><%= @tenant.updated_at %></td></tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="card mb-4">
          <div class="card-header"><strong>Feature Flags</strong></div>
          <div class="card-body p-0">
            <table class="table table-hover mb-0">
              <tbody>
                <%= if @tenant.feature_flags == %{} do %>
                  <tr><td class="text-muted">No feature flags set</td></tr>
                <% else %>
                  <%= for {key, value} <- Enum.sort_by(@tenant.feature_flags, &elem(&1, 0)) do %>
                    <tr><td><%= key %></td><td><%= inspect(value) %></td></tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>

        <div class="card mb-4">
          <div class="card-header"><strong>Database</strong></div>
          <div class="card-body p-0">
            <table class="table table-hover mb-0">
              <tbody>
                <tr>
                  <td>postgres_version</td>
                  <td>
                    <%= case @pg_version do %>
                      <% nil -> %>
                      <% {:ok, version} -> %><span class="text-monospace"><%= version %></span>
                      <% {:error, msg} -> %><span class="text-danger"><%= msg %></span>
                    <% end %>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="card mb-4" id="privileges">
          <div class="card-header"><strong>Privileges</strong></div>
          <div class="card-body">
            <%= case @privileges do %>
              <% nil -> %>
              <% {:ok, privileges} -> %><%= privileges_section(privileges) %>
              <% {:error, msg} -> %><p class="text-danger mb-0"><%= msg %></p>
            <% end %>
          </div>
        </div>

        <div class="card mb-4">
          <div class="card-header"><strong>Runtime</strong></div>
          <div class="card-body p-0">
            <table class="table table-hover mb-0">
              <tbody>
                <tr>
                  <td>connect</td>
                  <td><%= status_cell(@runtime.connect) %></td>
                  <td>
                    <button
                      phx-click="shutdown_connect"
                      data-confirm={"Shutdown Connect for #{@external_id}?"}
                      class="btn btn-sm btn-danger"
                    >
                      Shutdown
                    </button>
                  </td>
                </tr>
                <tr>
                  <td>replication_connection</td>
                  <td><%= status_cell(@runtime.replication) %></td>
                  <td></td>
                </tr>
                <tr>
                  <td>postgres_cdc_rls</td>
                  <td><%= status_cell(@runtime.cdc_rls) %></td>
                  <td>
                    <button
                      phx-click="shutdown_cdc_rls"
                      data-confirm={"Shutdown Postgres Replication (CDC RLS) for #{@external_id}?"}
                      class="btn btn-sm btn-danger"
                    >
                      Shutdown
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <div class="card mb-4">
          <div class="card-header"><strong>Connected users per region</strong></div>
          <div class="card-body p-0">
            <table class="table table-hover mb-0">
              <thead>
                <tr><th>region</th><th>nodes</th><th>connected</th></tr>
              </thead>
              <tbody>
                <%= for region <- @runtime.users.regions do %>
                  <tr>
                    <td><%= region.region %></td>
                    <td><%= region.nodes %></td>
                    <td><%= region.count %></td>
                  </tr>
                <% end %>
                <tr class="font-weight-bold">
                  <td>total (cluster)</td>
                  <td></td>
                  <td><%= @runtime.users.total %></td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <%= for ext <- @tenant.extensions do %>
          <div class="card mb-4">
            <div class="card-header"><strong>Extension: <%= ext.type %></strong></div>
            <div class="card-body p-0">
              <table class="table table-hover mb-0">
                <tbody>
                  <%= for {key, value} <- ext.settings do %>
                    <tr><td><%= key %></td><td><%= value %></td></tr>
                  <% end %>
                  <tr><td>inserted_at</td><td><%= ext.inserted_at %></td></tr>
                  <tr><td>updated_at</td><td><%= ext.updated_at %></td></tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    """
  end

  @secret_settings ["db_password"]
  @encrypted_settings ["db_host", "db_port", "db_name", "db_user"]

  defp prepare_tenant(tenant) do
    %{tenant | extensions: Enum.map(tenant.extensions, &prepare_extension/1)}
  end

  defp prepare_extension(ext) do
    settings =
      ext.settings
      |> Map.drop(@secret_settings)
      |> Enum.map(fn
        {key, value} when key in @encrypted_settings -> {key, Crypto.decrypt!(value)}
        {key, value} -> {key, value}
      end)

    resolved_host =
      case List.keyfind(settings, "db_host", 0) do
        {"db_host", host} -> resolve_host(host)
        nil -> nil
      end

    settings =
      settings
      |> then(fn s ->
        if resolved_host, do: [{"db_host_resolved", resolved_host} | s], else: s
      end)
      |> Enum.sort_by(&elem(&1, 0))

    %{ext | settings: settings}
  end

  # Cheap, RPC-free runtime status pulled from :syn metadata and Census' cached
  # membership counts. No database connections or remote calls are made here.
  defp runtime_info(tenant_id) do
    %{
      connect: process_status(Connect.whereis(tenant_id)),
      replication: replication_status(tenant_id),
      cdc_rls: cdc_rls_status(tenant_id),
      users: users_by_region(tenant_id)
    }
  end

  defp cdc_rls_status(tenant_id) do
    case PostgresCdcRls.get_manager_conn(tenant_id) do
      {:ok, manager, _conn} -> process_status(manager)
      {:error, _} -> %{up: false, node: nil}
    end
  end

  defp replication_status(tenant_id) do
    case Connect.replication_status(tenant_id) do
      {:ok, pid} -> process_status(pid)
      {:error, :not_connected} -> %{up: false, node: nil}
    end
  end

  defp process_status(pid) when is_pid(pid), do: %{up: true, node: node(pid)}
  defp process_status(_), do: %{up: false, node: nil}

  defp users_by_region(tenant_id) do
    regions =
      for region <- Enum.sort(Nodes.all_node_regions()) do
        nodes = Nodes.region_nodes(region)
        count = Enum.sum_by(nodes, &UsersCounter.tenant_users(tenant_id, &1))
        %{region: region, nodes: length(nodes), count: count}
      end

    %{total: UsersCounter.tenant_users(tenant_id), regions: regions}
  end

  defp status_cell(%{up: true, node: node}) do
    assigns = %{node: node}

    ~H"""
    <span class="text-success">up</span> <span class="text-monospace">(<%= @node %>)</span>
    """
  end

  defp status_cell(%{up: false}) do
    assigns = %{}

    ~H"""
    <span class="text-muted">not connected</span>
    """
  end

  defp privileges_section(privileges) do
    assigns =
      Map.put(privileges, :not_executable, Enum.count(privileges.functions, fn [_, _, _, can] -> !can end))

    # Sections start collapsed because the ACLs make them long. The functions section opens on its
    # own when an owner can't execute its function. Patches from auto-refresh leave `open` alone, so
    # a section the user opened stays open.
    ~H"""
    <p class="text-muted small">
      Read in a read-only transaction as <span class="text-monospace"><%= @role %></span>, the role tenant migrations
      run as. An empty ACL cell means the built-in default: the owner and PUBLIC.
    </p>

    <details id="privileges-default-section" class="mb-3" phx-mounted={JS.ignore_attributes("open")}>
      <summary>
        <h6 class="d-inline">
          Default privileges of <span class="text-monospace"><%= @role %></span> (<%= length(@default_privileges) %>)
        </h6>
      </summary>
      <table class="table table-sm mt-2 mb-0" id="privileges-default">
        <thead>
          <tr><th>schema</th><th>object type</th><th>acl</th></tr>
        </thead>
        <tbody>
          <%= if @default_privileges == [] do %>
            <tr><td colspan="3" class="text-muted">None set</td></tr>
          <% end %>
          <%= for [_role, schema, object_type, acl] <- @default_privileges do %>
            <tr>
              <td><%= schema %></td>
              <td><%= object_type %></td>
              <td class="text-monospace" style="overflow-wrap: anywhere;"><%= acl %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </details>

    <details
      id="privileges-functions-section"
      class="mb-3"
      open={@not_executable > 0}
      phx-mounted={JS.ignore_attributes("open")}
    >
      <summary>
        <h6 class="d-inline">realtime functions (<%= length(@functions) %>)</h6>
        <%= if @not_executable > 0 do %>
          <span class="text-danger">· <%= @not_executable %> not executable by their owner</span>
        <% end %>
      </summary>
      <table class="table table-sm mt-2 mb-0" id="privileges-functions">
        <thead>
          <tr><th>function</th><th>owner</th><th>owner can execute</th><th>acl</th></tr>
        </thead>
        <tbody>
          <%= for [function, owner, acl, owner_can_execute] <- @functions do %>
            <tr>
              <td class="text-monospace" style="overflow-wrap: anywhere;"><%= function %></td>
              <td><%= owner %></td>
              <td>
                <%= if owner_can_execute do %>
                  yes
                <% else %>
                  <span class="text-danger">no</span>
                <% end %>
              </td>
              <td class="text-monospace" style="overflow-wrap: anywhere;"><%= acl %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </details>

    <details id="privileges-tables-section" class="mb-3" phx-mounted={JS.ignore_attributes("open")}>
      <summary><h6 class="d-inline">realtime tables (<%= length(@tables) %>)</h6></summary>
      <table class="table table-sm mt-2 mb-0" id="privileges-tables">
        <thead>
          <tr><th>table</th><th>owner</th><th>acl</th></tr>
        </thead>
        <tbody>
          <%= for [table, owner, acl] <- @tables do %>
            <tr>
              <td class="text-monospace" style="overflow-wrap: anywhere;"><%= table %></td>
              <td><%= owner %></td>
              <td class="text-monospace" style="overflow-wrap: anywhere;"><%= acl %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </details>

    <details id="privileges-event-triggers-section" phx-mounted={JS.ignore_attributes("open")}>
      <summary><h6 class="d-inline">Event triggers (<%= length(@event_triggers) %>)</h6></summary>
      <table class="table table-sm mt-2 mb-0" id="privileges-event-triggers">
        <thead>
          <tr><th>name</th><th>event</th><th>owner</th><th>enabled</th><th>function</th><th>tags</th></tr>
        </thead>
        <tbody>
          <%= if @event_triggers == [] do %>
            <tr><td colspan="6" class="text-muted">None</td></tr>
          <% end %>
          <%= for [name, event, owner, enabled, function, tags] <- @event_triggers do %>
            <tr>
              <td><%= name %></td>
              <td><%= event %></td>
              <td><%= owner %></td>
              <td><%= enabled %></td>
              <td class="text-monospace" style="overflow-wrap: anywhere;"><%= function %></td>
              <td><%= tags %></td>
            </tr>
          <% end %>
        </tbody>
      </table>
    </details>
    """
  end

  # The reads run in an unlinked task that starts the connection. The connection pool traps exits
  # and stops when the process that started it exits, so the connection closes when the task
  # returns, crashes or is killed on timeout, and none of that can take the dashboard down.
  defp fetch_database_info(%Tenant{} = tenant) do
    task = Task.Supervisor.async_nolink(Realtime.TaskSupervisor, fn -> read_database_info(tenant) end)

    case Task.yield(task, @database_info_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> database_read_failed(reason)
      nil -> database_read_failed(:timeout)
    end
  end

  defp database_read_failed(reason) do
    log_warning("TenantInfoDatabaseFailed", reason)
    error = {:error, "Failed to read the tenant database: #{inspect(reason)}"}
    {error, error}
  end

  defp read_database_info(tenant) do
    with {:ok, settings} <- Database.from_tenant(tenant, @application_name, :stop),
         {:ok, conn} <- Database.connect_db(settings) do
      {fetch_pg_version(conn), fetch_privileges(conn)}
    else
      {:error, reason} ->
        log_warning("TenantInfoPgVersionFailed", reason)
        error = {:error, "Failed to connect to the tenant database: #{inspect(reason)}"}
        {error, error}
    end
  end

  defp fetch_pg_version(conn) do
    case Postgrex.query(conn, "SELECT version()", []) do
      {:ok, %{rows: [[version]]}} ->
        {:ok, version}

      {:error, reason} ->
        log_warning("TenantInfoPgVersionFailed", reason)
        {:error, "Failed to query postgres version: #{inspect(reason)}"}
    end
  end

  # Tenant migrations connect as the same role this page does, so that role's default privileges
  # are the ACL every function they create starts from.
  @default_privileges_query """
  SELECT r.rolname,
         coalesce(n.nspname, '(all schemas)'),
         CASE d.defaclobjtype
           WHEN 'r' THEN 'tables'
           WHEN 'S' THEN 'sequences'
           WHEN 'f' THEN 'functions'
           WHEN 'T' THEN 'types'
           WHEN 'n' THEN 'schemas'
           ELSE d.defaclobjtype::text
         END,
         d.defaclacl::text
  FROM pg_catalog.pg_default_acl d
  JOIN pg_catalog.pg_roles r ON r.oid = d.defaclrole
  LEFT JOIN pg_catalog.pg_namespace n ON n.oid = d.defaclnamespace
  WHERE r.rolname = current_user
  ORDER BY n.nspname NULLS FIRST, 3
  """

  @functions_query """
  SELECT p.oid::pg_catalog.regprocedure::text,
         pg_catalog.pg_get_userbyid(p.proowner),
         p.proacl::text,
         pg_catalog.has_function_privilege(p.proowner, p.oid, 'EXECUTE')
  FROM pg_catalog.pg_proc p
  JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'realtime'
  ORDER BY 1
  """

  @tables_query """
  SELECT c.oid::pg_catalog.regclass::text,
         pg_catalog.pg_get_userbyid(c.relowner),
         c.relacl::text
  FROM pg_catalog.pg_class c
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'realtime' AND c.relkind IN ('r', 'p') AND NOT c.relispartition
  ORDER BY 1
  """

  @event_triggers_query """
  SELECT e.evtname,
         e.evtevent,
         pg_catalog.pg_get_userbyid(e.evtowner),
         CASE e.evtenabled
           WHEN 'O' THEN 'enabled'
           WHEN 'D' THEN 'disabled'
           WHEN 'R' THEN 'replica'
           WHEN 'A' THEN 'always'
         END,
         e.evtfoid::pg_catalog.regproc::text,
         coalesce(pg_catalog.array_to_string(e.evttags, ', '), '')
  FROM pg_catalog.pg_event_trigger e
  ORDER BY 1
  """

  defp fetch_privileges(conn) do
    result =
      Postgrex.transaction(conn, fn conn ->
        with {:ok, _} <- Postgrex.query(conn, "SET TRANSACTION READ ONLY", []),
             {:ok, _} <- Postgrex.query(conn, "SET LOCAL statement_timeout = #{@privileges_statement_timeout}", []),
             {:ok, %{rows: [[role]]}} <- Postgrex.query(conn, "SELECT current_user::text", []),
             {:ok, default_privileges} <- Postgrex.query(conn, @default_privileges_query, []),
             {:ok, functions} <- Postgrex.query(conn, @functions_query, []),
             {:ok, tables} <- Postgrex.query(conn, @tables_query, []),
             {:ok, event_triggers} <- Postgrex.query(conn, @event_triggers_query, []) do
          %{
            role: role,
            default_privileges: default_privileges.rows,
            functions: functions.rows,
            tables: tables.rows,
            event_triggers: event_triggers.rows
          }
        else
          {:error, reason} -> Postgrex.rollback(conn, reason)
        end
      end)

    case result do
      {:ok, privileges} ->
        {:ok, privileges}

      {:error, reason} ->
        log_warning("TenantInfoPrivilegesFailed", reason)
        {:error, "Failed to query privileges: #{inspect(reason)}"}
    end
  end

  defp resolve_host(host) do
    host_charlist = String.to_charlist(host)

    v4 =
      case :inet.getaddrs(host_charlist, :inet) do
        {:ok, ips} -> ips
        _ -> []
      end

    v6 =
      case :inet.getaddrs(host_charlist, :inet6) do
        {:ok, ips} -> ips
        _ -> []
      end

    ips = (v4 ++ v6) |> Enum.map(&:inet.ntoa/1) |> Enum.map(&to_string/1)

    case ips do
      [] -> "unresolved"
      _ -> Enum.join(ips, ", ")
    end
  end
end
