defmodule RealtimeWeb.Dashboard.TenantInfo.Privileges do
  @moduledoc """
  The Privileges section of the Tenant Info dashboard page (`RealtimeWeb.Dashboard.TenantInfo`).

  It shows who owns the realtime objects in the tenant database and who can execute the realtime functions,
  so a privilege problem can be diagnosed without SQL access to that database. The section has four parts.
  Each part runs its own query, in a read-only transaction, only once it is first opened.
  """
  use Phoenix.Component
  use Realtime.Logs

  import RealtimeWeb.Dashboard.TenantInfo.Components

  alias RealtimeWeb.Dashboard.TenantInfo.TenantDatabase

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

  @queries %{
    "default" => @default_privileges_query,
    "functions" => @functions_query,
    "tables" => @tables_query,
    "event-triggers" => @event_triggers_query
  }

  @doc """
  Reads one part of the section from the database of the tenant `external_id`. `section` is the
  `phx-value-section` of the part: `"default"`, `"functions"`, `"tables"` or `"event-triggers"`.
  """
  @spec read(String.t(), String.t()) :: TenantDatabase.result()
  def read(external_id, section) when is_map_key(@queries, section) do
    query = Map.fetch!(@queries, section)
    TenantDatabase.read(external_id, &query_rows(&1, query))
  end

  defp query_rows(conn, query) do
    case TenantDatabase.read_only(conn, &Postgrex.query!(&1, query, []).rows) do
      {:ok, rows} ->
        {:ok, rows}

      {:error, reason} ->
        log_warning("TenantInfoPrivilegesFailed", reason)
        {:error, "Failed to query privileges: #{inspect(reason)}"}
    end
  end

  @doc "The Privileges card. `privileges` maps each part read so far to what `read/2` returned."
  attr :privileges, :map, required: true

  def card(assigns) do
    assigns = assign(assigns, :not_executable, not_executable(assigns.privileges["functions"]))

    ~H"""
    <.section id="privileges" title="Privileges" flush={false}>
      <p class="text-muted small">
        Each section reads the tenant database when first opened, in a read-only transaction as the role tenant
        migrations run as. An empty ACL cell means the built-in default: the owner and PUBLIC.
      </p>

      <.lazy_section
        :let={rows}
        id="privileges-default-section"
        class="mb-3"
        event="load_privileges"
        section="default"
        title="Default privileges of the migration role"
        count={&length/1}
        state={@privileges["default"]}
      >
        <.table id="privileges-default" class="table table-sm mt-2 mb-0" rows={rows} empty="None set">
          <:col :let={[role, _, _, _]} label="role">{role}</:col>
          <:col :let={[_, schema, _, _]} label="schema">{schema}</:col>
          <:col :let={[_, _, object_type, _]} label="object type">{object_type}</:col>
          <:col :let={[_, _, _, acl]} label="acl" code>{acl}</:col>
        </.table>
      </.lazy_section>

      <.lazy_section
        :let={rows}
        id="privileges-functions-section"
        class="mb-3"
        event="load_privileges"
        section="functions"
        title="realtime functions"
        count={&length/1}
        state={@privileges["functions"]}
      >
        <:warning :if={@not_executable > 0}>{@not_executable} not executable by their owner</:warning>
        <.table id="privileges-functions" class="table table-sm mt-2 mb-0" rows={rows}>
          <:col :let={[function, _, _, _]} label="function" code>{function}</:col>
          <:col :let={[_, owner, _, _]} label="owner">{owner}</:col>
          <:col :let={[_, _, _, can_execute]} label="owner can execute">
            <.flag value={can_execute} expected={true} />
          </:col>
          <:col :let={[_, _, acl, _]} label="acl" code>{acl}</:col>
        </.table>
      </.lazy_section>

      <.lazy_section
        :let={rows}
        id="privileges-tables-section"
        class="mb-3"
        event="load_privileges"
        section="tables"
        title="realtime tables"
        count={&length/1}
        state={@privileges["tables"]}
      >
        <.table id="privileges-tables" class="table table-sm mt-2 mb-0" rows={rows}>
          <:col :let={[table, _, _]} label="table" code>{table}</:col>
          <:col :let={[_, owner, _]} label="owner">{owner}</:col>
          <:col :let={[_, _, acl]} label="acl" code>{acl}</:col>
        </.table>
      </.lazy_section>

      <.lazy_section
        :let={rows}
        id="privileges-event-triggers-section"
        event="load_privileges"
        section="event-triggers"
        title="Event triggers"
        count={&length/1}
        state={@privileges["event-triggers"]}
      >
        <.table id="privileges-event-triggers" class="table table-sm mt-2 mb-0" rows={rows} empty="None">
          <:col :let={[name, _, _, _, _, _]} label="name">{name}</:col>
          <:col :let={[_, event, _, _, _, _]} label="event">{event}</:col>
          <:col :let={[_, _, owner, _, _, _]} label="owner">{owner}</:col>
          <:col :let={[_, _, _, enabled, _, _]} label="enabled">{enabled}</:col>
          <:col :let={[_, _, _, _, function, _]} label="function" code>{function}</:col>
          <:col :let={[_, _, _, _, _, tags]} label="tags">{tags}</:col>
        </.table>
      </.lazy_section>
    </.section>
    """
  end

  defp not_executable({:ok, functions}), do: Enum.count(functions, fn [_, _, _, can_execute] -> !can_execute end)
  defp not_executable(_), do: 0
end
