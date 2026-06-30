defmodule RealtimeWeb.Dashboard.TenantInfo do
  @moduledoc """
  Live Dashboard page to inspect tenant and extension information by external_id.
  Secrets (jwt_secret and encrypted extension fields) are never displayed.
  """
  use Phoenix.LiveDashboard.PageBuilder
  use Realtime.Logs

  alias Extensions.PostgresCdcRls
  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Database
  alias Realtime.Nodes
  alias Realtime.Tenants.Connect
  alias Realtime.UsersCounter

  @application_name "realtime_dashboard_tenant_info"

  @impl true
  def menu_link(_, _), do: {:ok, "Tenant Info"}

  @impl true
  def mount(_params, _, socket) do
    {:ok, assign(socket, external_id: "", tenant: nil, pg_version: nil, runtime: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"external_id" => ref}, _uri, socket) when ref != "" do
    ref = String.trim(ref)

    case Api.get_tenant_by_external_id(ref) do
      nil ->
        {:noreply,
         assign(socket, external_id: ref, tenant: nil, pg_version: nil, runtime: nil, error: "Tenant not found")}

      %Tenant{} = tenant ->
        {:noreply,
         assign(socket,
           external_id: ref,
           tenant: prepare_tenant(tenant),
           pg_version: fetch_pg_version(tenant),
           runtime: runtime_info(ref),
           error: nil
         )}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, external_id: "", tenant: nil, pg_version: nil, runtime: nil, error: nil)}
  end

  @impl true
  def handle_event("lookup", %{"external_id" => ref}, socket) do
    ref = String.trim(ref)
    {:noreply, push_patch(socket, to: "/admin/dashboard/tenant_info?external_id=#{URI.encode(ref)}")}
  end

  @impl true
  # Auto-refresh (the dashboard's "refresh every" selector) only recomputes the
  # cheap runtime info. pg_version is intentionally not refreshed as it opens a
  # database connection.
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

      <%= if @tenant do %>
        <h6 class="mt-4">Tenant</h6>
        <table class="table table-hover">
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

        <h6 class="mt-4">Database</h6>
        <table class="table table-hover">
          <tbody>
            <tr>
              <td>postgres_version</td>
              <td>
                <%= case @pg_version do %>
                  <% nil -> %>
                  <% {:ok, version} -> %><span class="font-monospace"><%= version %></span>
                  <% {:error, msg} -> %><span class="text-danger"><%= msg %></span>
                <% end %>
              </td>
            </tr>
          </tbody>
        </table>

        <h6 class="mt-4">Runtime</h6>
        <table class="table table-hover">
          <tbody>
            <tr>
              <td>connect</td>
              <td><%= status_cell(@runtime.connect) %></td>
            </tr>
            <tr>
              <td>replication_connection</td>
              <td><%= status_cell(@runtime.replication) %></td>
            </tr>
            <tr>
              <td>postgres_cdc_rls</td>
              <td><%= status_cell(@runtime.cdc_rls) %></td>
            </tr>
          </tbody>
        </table>

        <h6 class="mt-4">Connected users per region</h6>
        <table class="table table-hover">
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

        <%= for ext <- @tenant.extensions do %>
          <h6 class="mt-4">Extension: <%= ext.type %></h6>
          <table class="table table-hover">
            <tbody>
              <%= for {key, value} <- ext.settings do %>
                <tr><td><%= key %></td><td><%= value %></td></tr>
              <% end %>
              <tr><td>inserted_at</td><td><%= ext.inserted_at %></td></tr>
              <tr><td>updated_at</td><td><%= ext.updated_at %></td></tr>
            </tbody>
          </table>
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
    <span class="text-success">up</span> <span class="font-monospace">(<%= @node %>)</span>
    """
  end

  defp status_cell(%{up: false}) do
    assigns = %{}

    ~H"""
    <span class="text-muted">not connected</span>
    """
  end

  defp fetch_pg_version(%Tenant{} = tenant) do
    with {:ok, settings} <- Database.from_tenant(tenant, @application_name, :stop),
         {:ok, conn} <- Database.connect_db(settings),
         {:ok, %{rows: [[version]]}} <- Postgrex.query(conn, "SELECT version()", []) do
      {:ok, version}
    else
      {:error, reason} ->
        log_warning("TenantInfoPgVersionFailed", reason)
        {:error, "Failed to query postgres version: #{inspect(reason)}"}
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
