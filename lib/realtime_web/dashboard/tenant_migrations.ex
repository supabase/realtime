defmodule RealtimeWeb.Dashboard.TenantMigrations do
  @moduledoc """
  Live Dashboard page to inspect tenant migrations state.

  Requires `pgdelta` on `$PATH`.

  Regenerate the baseline with `mix realtime.export_tenant_db_baseline`.
  """
  use Phoenix.LiveDashboard.PageBuilder
  use Realtime.Logs

  alias Realtime.Api
  alias Realtime.Api.Tenant
  alias Realtime.Database

  @pg_delta_filter ~s({"*/schema": "realtime"})
  @application_name "realtime_dashboard_tenant_migrations"
  @query_timeout 30_000
  @schema_migrations_query "SELECT version, inserted_at FROM realtime.schema_migrations ORDER BY version DESC"

  @impl true
  def menu_link(_, _), do: {:ok, "Tenant Migrations"}

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       external_id: "",
       tenant: nil,
       schema_migrations: nil,
       pg_delta: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"external_id" => ref}, _uri, socket) when ref != "" do
    ref = String.trim(ref)

    with %Tenant{} = tenant <- Api.get_tenant_by_external_id(ref),
         {:ok, settings} <- Database.from_tenant(tenant, @application_name, :stop),
         {:ok, db_conn} <- Database.connect_db(settings) do
      {:noreply,
       assign(socket,
         external_id: ref,
         tenant: tenant,
         schema_migrations: fetch_schema_migrations(db_conn),
         pg_delta: run_pg_delta(settings),
         error: nil
       )}
    else
      nil ->
        {:noreply, assign_error(socket, ref, "Tenant not found")}

      {:error, reason} ->
        log_warning("TenantMigrationsConnectFailed", reason)
        {:noreply, assign_error(socket, ref, "Failed to connect to tenant DB: #{inspect(reason)}")}
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     assign(socket,
       external_id: "",
       tenant: nil,
       schema_migrations: nil,
       pg_delta: nil,
       error: nil
     )}
  end

  @impl true
  def handle_event("lookup", %{"external_id" => ref}, socket) do
    ref = String.trim(ref)
    {:noreply, push_patch(socket, to: "/admin/dashboard/tenant_migrations?external_id=#{URI.encode(ref)}")}
  end

  @impl true
  def handle_event(
        "apply_plan",
        _params,
        %{
          assigns: %{
            tenant: %Tenant{} = tenant,
            external_id: ref,
            pg_delta: {:ok, %{status: :changes, sql: sql}}
          }
        } = socket
      ) do
    case apply_pg_delta(tenant, sql) do
      :ok ->
        {:noreply, push_patch(socket, to: "/admin/dashboard/tenant_migrations?external_id=#{URI.encode(ref)}")}

      {:error, msg} ->
        {:noreply, assign(socket, error: msg)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="phx-dashboard-section">
      <h5 class="card-title">Tenant Migrations</h5>
      <p class="text-muted">
        Inspect a tenant's applied migrations and drift against the baseline schema snapshot.
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
        <button type="submit" class="btn btn-primary">Lookup</button>
      </form>

      <%= if @error do %>
        <p class="text-danger"><%= @error %></p>
      <% end %>

      <%= if @tenant do %>
        <h6 class="mt-4">realtime.schema_migrations</h6>
        <%= schema_migrations(@schema_migrations) %>

        <h6 class="mt-4">pg-delta plan vs baseline</h6>
        <%= pg_delta_plan(@pg_delta) %>
      <% end %>
    </div>
    """
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

  defp pg_delta_plan(nil) do
    assigns = %{}
    ~H""
  end

  defp pg_delta_plan({:error, msg}) do
    assigns = %{msg: msg}

    ~H"""
    <div class="alert alert-danger">
      <strong>Error:</strong>
      <pre class="mb-0 mt-2" style="white-space: pre-wrap; word-break: break-word;"><%= @msg %></pre>
    </div>
    """
  end

  defp pg_delta_plan({:ok, %{status: :no_changes}}) do
    assigns = %{}

    ~H"""
    <div class="alert alert-success mb-0">
      No drift detected. Tenant schema matches the baseline.
    </div>
    """
  end

  defp pg_delta_plan({:ok, %{status: :changes, sql: sql}}) do
    assigns = %{sql: sql}

    ~H"""
    <div class="alert alert-warning">
      <strong>Drift detected between tenant and baseline.</strong>
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
        phx-click="apply_plan"
        phx-disable-with="Applying..."
        data-confirm="Apply this SQL plan to the tenant database? This may include destructive statements and is irreversible."
      >
        Apply
      </button>
    </div>
    """
  end

  defp assign_error(socket, ref, msg) do
    assign(socket,
      external_id: ref,
      tenant: nil,
      schema_migrations: nil,
      pg_delta: nil,
      error: msg
    )
  end

  defp fetch_schema_migrations(db_conn) do
    case Postgrex.query(db_conn, @schema_migrations_query, [], timeout: @query_timeout) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [v, ts] -> [to_string(v), format_ts(ts)] end)}

      {:error, %{postgres: %{message: message}}} ->
        log_warning("TenantMigrationsSchemaMigrationsQueryError", message)
        {:error, message}

      {:error, reason} ->
        log_warning("TenantMigrationsSchemaMigrationsQueryFailed", reason)
        {:error, inspect(reason)}
    end
  end

  defp format_ts(%NaiveDateTime{} = t), do: NaiveDateTime.to_string(t)
  defp format_ts(%DateTime{} = t), do: DateTime.to_string(t)
  defp format_ts(other), do: to_string(other)

  defp postgres_url(%Database{} = db) do
    sslmode = if db.ssl, do: "require", else: "disable"

    IO.iodata_to_binary([
      "postgresql://",
      URI.encode_www_form(db.username),
      ":",
      URI.encode_www_form(db.password),
      "@",
      db.hostname,
      ":",
      Integer.to_string(db.port),
      "/",
      db.database,
      "?sslmode=",
      sslmode
    ])
  end

  defp run_pg_delta(%Database{} = settings) do
    case System.find_executable("pgdelta") do
      nil ->
        log_warning("TenantMigrationsPgDeltaMissing", "pgdelta not found on PATH")
        {:error, "pgdelta not found on PATH"}

      path ->
        baseline = Application.app_dir(:realtime, "priv/repo/tenant_db_baseline.json")

        args = [
          "plan",
          "--source",
          postgres_url(settings),
          "--target",
          baseline,
          "--filter",
          @pg_delta_filter,
          "--format",
          "sql"
        ]

        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} ->
            {:ok, %{status: :no_changes, sql: output}}

          {output, 2} ->
            {:ok, %{status: :changes, sql: output}}

          {output, code} ->
            log_warning("TenantMigrationsPgDeltaNonZeroExit", "exit #{code}: #{output}")
            {:error, "pg-delta exited #{code}:\n#{output}"}
        end
    end
  end

  defp apply_pg_delta(%Tenant{} = tenant, sql) do
    with {:ok, settings} <- Database.from_tenant(tenant, @application_name, :stop),
         {:ok, db_conn} <- Database.connect_db(settings),
         {:ok, _} <- Postgrex.query(db_conn, sql, [], query_type: :text, timeout: @query_timeout) do
      :ok
    else
      {:error, %{postgres: %{message: message}}} ->
        log_warning("TenantMigrationsApplyFailed", message)
        {:error, "Apply failed: #{message}"}

      {:error, reason} ->
        log_warning("TenantMigrationsApplyFailed", reason)
        {:error, "Apply failed: #{inspect(reason)}"}
    end
  end
end
