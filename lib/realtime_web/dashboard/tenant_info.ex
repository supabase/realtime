defmodule RealtimeWeb.Dashboard.TenantInfo do
  @moduledoc """
  Live Dashboard page to inspect tenant and extension information by external_id.
  Secrets (jwt_secret and encrypted extension fields) are never displayed.

  The page itself shows the tenant, its runtime processes and its connected users. Two sections read the
  tenant database, each only once it is first opened:

    * Privileges (`RealtimeWeb.Dashboard.TenantInfo.Privileges`) shows who owns the realtime objects and
      who can execute the realtime functions.
    * Policies (`RealtimeWeb.Dashboard.TenantInfo.PolicyEval`) shows what policy_eval makes of the
      policies on `realtime.messages`.

  Every read of the tenant database goes through `RealtimeWeb.Dashboard.TenantInfo.TenantDatabase`.
  The components that the sections share are in `RealtimeWeb.Dashboard.TenantInfo.Components`.
  """
  use Phoenix.LiveDashboard.PageBuilder
  use Realtime.Logs

  import RealtimeWeb.Dashboard.TenantInfo.Components

  alias Extensions.PostgresCdcRls
  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Crypto
  alias Realtime.Nodes
  alias Realtime.Tenants.Connect
  alias Realtime.UsersCounter
  alias RealtimeWeb.Dashboard.TenantInfo.PolicyEval
  alias RealtimeWeb.Dashboard.TenantInfo.Privileges
  alias RealtimeWeb.Dashboard.TenantInfo.TenantDatabase

  @cdc_rls_stop_timeout 5_000

  @tenant_fields ~w(external_id name suspend private_only presence_enabled postgres_cdc_default broadcast_adapter
    max_concurrent_users max_events_per_second max_bytes_per_second max_channels_per_client max_joins_per_second
    max_presence_events_per_second max_payload_size_in_kb max_client_presence_events_per_window
    client_presence_window_ms migrations_ran inserted_at updated_at)a

  @empty_assigns [pg_version: nil, privileges: %{}, policy_eval: nil, runtime: nil, error: nil, action_msg: nil]

  @impl true
  def menu_link(_, _), do: {:ok, "Tenant Info"}

  @impl true
  def mount(_params, _, socket) do
    {:ok, assign(socket, [external_id: "", tenant: nil] ++ @empty_assigns)}
  end

  @impl true
  def handle_params(%{"external_id" => ref}, _uri, socket) when ref != "" do
    ref = String.trim(ref)
    socket = assign(socket, [external_id: ref, tenant: nil] ++ @empty_assigns)

    case Api.get_tenant_by_external_id(ref) do
      nil ->
        {:noreply, assign(socket, error: "Tenant not found")}

      %Tenant{} = tenant ->
        {:noreply,
         assign(socket,
           tenant: prepare_tenant(tenant),
           pg_version: TenantDatabase.read(tenant, &fetch_pg_version/1),
           runtime: runtime_info(ref)
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

  # A section's summary sends its load event on every click, closing included. Only the first one
  # reads, so a section keeps what it showed until the next lookup.
  def handle_event("load_privileges", %{"section" => section}, %{assigns: %{external_id: ref}} = socket)
      when ref != "" do
    if Map.has_key?(socket.assigns.privileges, section) do
      {:noreply, socket}
    else
      {:noreply, update(socket, :privileges, &Map.put(&1, section, Privileges.read(ref, section)))}
    end
  end

  def handle_event("load_policy_eval", _params, %{assigns: %{external_id: ref}} = socket) when ref != "" do
    if socket.assigns.policy_eval do
      {:noreply, socket}
    else
      {:noreply, assign(socket, policy_eval: PolicyEval.read(ref))}
    end
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

      <p :if={@error} class="text-danger">{@error}</p>
      <p :if={@action_msg} class="text-success">{@action_msg}</p>

      <div :if={@tenant}>
        <.section title="Tenant">
          <.kv_table rows={tenant_rows(@tenant)} />
        </.section>

        <.section title="Feature Flags">
          <.kv_table rows={feature_flag_rows(@tenant)} empty="No feature flags set" />
        </.section>

        <.section title="Database">
          <table class="table table-hover mb-0">
            <tbody>
              <tr>
                <td>postgres_version</td>
                <td>
                  <%= case @pg_version do %>
                    <% nil -> %>
                    <% {:ok, version} -> %><span class="text-monospace">{version}</span>
                    <% {:error, message} -> %><span class="text-danger">{message}</span>
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </.section>

        <Privileges.card privileges={@privileges} />
        <PolicyEval.card state={@policy_eval} />

        <.section title="Runtime">
          <table class="table table-hover mb-0">
            <tbody>
              <tr>
                <td>connect</td>
                <td><.status process={@runtime.connect} /></td>
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
                <td><.status process={@runtime.replication} /></td>
                <td></td>
              </tr>
              <tr>
                <td>postgres_cdc_rls</td>
                <td><.status process={@runtime.cdc_rls} /></td>
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
        </.section>

        <.section title="Connected users per region">
          <table class="table table-hover mb-0">
            <thead>
              <tr><th>region</th><th>nodes</th><th>connected</th></tr>
            </thead>
            <tbody>
              <tr :for={region <- @runtime.users.regions}>
                <td>{region.region}</td>
                <td>{region.nodes}</td>
                <td>{region.count}</td>
              </tr>
              <tr class="font-weight-bold">
                <td>total (cluster)</td>
                <td></td>
                <td>{@runtime.users.total}</td>
              </tr>
            </tbody>
          </table>
        </.section>

        <.section :for={ext <- @tenant.extensions} title={"Extension: #{ext.type}"}>
          <.kv_table rows={extension_rows(ext)} />
        </.section>
      </div>
    </div>
    """
  end

  defp tenant_rows(tenant), do: Enum.map(@tenant_fields, &{&1, Map.get(tenant, &1)})

  defp feature_flag_rows(tenant) do
    tenant.feature_flags
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {key, value} -> {key, inspect(value)} end)
  end

  defp extension_rows(ext), do: ext.settings ++ [{"inserted_at", ext.inserted_at}, {"updated_at", ext.updated_at}]

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

  defp fetch_pg_version(conn) do
    case Postgrex.query(conn, "SELECT version()", []) do
      {:ok, %{rows: [[version]]}} ->
        {:ok, version}

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
