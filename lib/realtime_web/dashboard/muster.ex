defmodule RealtimeWeb.Dashboard.Muster do
  @moduledoc """
  Live Dashboard page showing the Muster coordinator state for the selected node.

  It surfaces the lifecycle status (`:ready` / `:converging` / `:rebalancing`)
  plus supporting detail (view hash, members, ring nodes, peers, snapshot
  bookkeeping, and per-group state counts) so an operator can eyeball this
  node's health at a glance. Use the node picker (top-right) to switch nodes;
  the page reads the selected node from `page.node` and RPCs it for the snapshot
  (the LiveView itself always runs on the serving node).
  """
  use Phoenix.LiveDashboard.PageBuilder

  # Lifecycle status -> Bootstrap contextual color.
  @status_colors %{
    ready: "success",
    converging: "warning",
    rebalancing: "danger"
  }

  # Order used to render the per-group state summary.
  @group_state_order [:occupied, :cooldown, :vacant_queued, :occupied_pending, :vacant_flushing]

  @impl true
  def menu_link(_, _), do: {:ok, "Muster"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, node_data: node_data(socket.assigns.page.node))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign(socket, node_data: node_data(socket.assigns.page.node))}
  end

  # Invoked by LiveDashboard's automatic refresh timer (enabled by default). Without
  # this, the timer would tick and re-render but never re-fetch the snapshot.
  @impl true
  def handle_refresh(socket) do
    {:noreply, assign(socket, node_data: node_data(socket.assigns.page.node))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="phx-dashboard-section">
      <div class="d-flex justify-content-between align-items-center mb-3">
        <h5 class="card-title mb-0">Muster</h5>
        <button phx-click="refresh" class="btn btn-sm btn-outline-secondary">Refresh</button>
      </div>
      <div class="card mb-3 border-primary">
        <div class="card-header d-flex justify-content-between align-items-center">
          <strong><%= @node_data.name %></strong>
          <%= if @node_data.error do %>
            <span class="badge bg-danger">unavailable</span>
          <% else %>
            <span class={"badge bg-#{status_color(@node_data.status)}"}>
              <%= inspect(@node_data.status) %>
            </span>
          <% end %>
        </div>
        <%= if @node_data.error do %>
          <div class="card-body text-danger small"><%= @node_data.error %></div>
        <% else %>
          <div class="card-body p-0">
            <table class="table table-sm table-hover mb-0">
              <thead><tr><th colspan="2" class="text-muted small ps-3">Cluster / readiness</th></tr></thead>
              <tbody>
                <tr><td class="ps-3">Scope</td><td><%= inspect(@node_data.scope) %></td></tr>
                <tr><td class="ps-3">Status</td><td><%= inspect(@node_data.status) %></td></tr>
                <tr><td class="ps-3">View Hash</td><td><code><%= inspect(@node_data.view_hash) %></code></td></tr>
                <tr><td class="ps-3">Members (<%= length(@node_data.members) %>)</td><td><%= inspect(@node_data.members) %></td></tr>
                <tr><td class="ps-3">Ring Nodes (<%= length(@node_data.ring_nodes) %>)</td><td><%= inspect(@node_data.ring_nodes) %></td></tr>
                <tr><td class="ps-3">Peers</td><td><%= @node_data.peers %></td></tr>
                <tr><td class="ps-3">Owed Snapshots</td><td><%= @node_data.owed_snapshots %></td></tr>
                <tr><td class="ps-3">Applied Snapshot Seq</td><td><%= inspect(@node_data.applied_snapshot_seq) %></td></tr>
              </tbody>
            </table>
            <table class="table table-sm table-hover mb-0 border-top">
              <thead>
                <tr><th colspan="2" class="text-muted small ps-3">As source (groups with local members)</th></tr>
              </thead>
              <tbody>
                <%= for {label, count} <- @node_data.group_counts do %>
                  <tr><td class="ps-3"><%= inspect(label) %></td><td><%= count %></td></tr>
                <% end %>
                <tr class="fw-bold"><td class="ps-3">total</td><td><%= @node_data.group_total %></td></tr>
              </tbody>
            </table>
            <table class="table table-sm table-hover mb-0 border-top">
              <thead>
                <tr><th colspan="2" class="text-muted small ps-3">As router (occupancy rows by source node)</th></tr>
              </thead>
              <tbody>
                <%= for {source_node, count} <- @node_data.occupancy_by_node do %>
                  <tr><td class="ps-3"><%= source_node %></td><td><%= count %></td></tr>
                <% end %>
                <tr class="fw-bold"><td class="ps-3">total present</td><td><%= @node_data.occupancy_row_count %></td></tr>
              </tbody>
            </table>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp status_color(status), do: Map.get(@status_colors, status, "secondary")

  # The page LiveView always runs on the serving node; `page.node` is the node
  # chosen in the picker (a URL param). So we gather locally only when that node
  # IS us, and RPC to gather_local_info/0 on the selected node otherwise.
  defp node_data(target) do
    base = %{name: target, error: nil}

    result =
      if target == node() do
        gather_local_info()
      else
        case :rpc.call(target, __MODULE__, :gather_local_info, [], 5_000) do
          {:badrpc, reason} -> {:error, "RPC failed: #{inspect(reason)}"}
          info -> info
        end
      end

    case result do
      {:ok, info} -> Map.merge(base, info)
      {:error, msg} -> Map.put(base, :error, msg)
    end
  end

  @doc """
  Builds the Muster summary for the configured scope on this node and folds it
  into the shape the page renders.

  Returns `{:error, message}` when no scope is configured or the coordinator is
  not running, so the page can surface a friendly error instead of crashing.
  """
  def gather_local_info do
    case Application.get_env(:realtime, :muster_scope) do
      nil ->
        {:error, "No Muster scope configured on this node"}

      scope ->
        try do
          {:ok, to_view(Forum.Muster.summary(scope))}
        catch
          :exit, reason ->
            {:error, "Muster coordinator unavailable: #{inspect(reason)}"}
        end
    end
  end

  defp to_view(s) do
    counts = s.group_state_counts
    group_counts = Enum.map(@group_state_order, fn state -> {state, Map.get(counts, state, 0)} end)

    %{
      scope: s.scope,
      status: s.status,
      view_hash: s.view_hash,
      members: s.members,
      ring_nodes: s.ring_nodes,
      peers: s.peers,
      owed_snapshots: s.owed_snapshots,
      applied_snapshot_seq: s.applied_snapshot_seq,
      occupancy_row_count: s.occupancy_row_count,
      occupancy_by_node: Enum.sort_by(s.occupancy_rows_by_node, fn {node, _} -> to_string(node) end),
      group_counts: group_counts,
      group_total: Map.get(counts, :total, 0)
    }
  end
end
