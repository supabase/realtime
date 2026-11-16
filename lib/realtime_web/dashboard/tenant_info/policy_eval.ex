defmodule RealtimeWeb.Dashboard.TenantInfo.PolicyEval do
  @moduledoc """
  The Policies section of the Tenant Info dashboard page (`RealtimeWeb.Dashboard.TenantInfo`).

  It shows what policy_eval makes of the policies on `realtime.messages` (`Realtime.Tenants.PolicyEvalReport`),
  so the fallbacks of shadow mode can be diagnosed. It reads with the loader of shadow mode
  (`Realtime.Tenants.PolicyEvalLoader`), in a read-only transaction, only once the section is first opened.
  """
  use Phoenix.Component
  use Realtime.Logs

  import RealtimeWeb.Dashboard.TenantInfo.Components

  alias Realtime.Tenants.PolicyEvalLoader
  alias Realtime.Tenants.PolicyEvalReport
  alias RealtimeWeb.Dashboard.TenantInfo.TenantDatabase

  @doc "Reads the policies from the database of the tenant `external_id` and builds the report."
  @spec read(String.t()) :: TenantDatabase.result()
  def read(external_id), do: TenantDatabase.read(external_id, &build_report/1)

  # The reads of shadow mode (PolicyEvalLoader.read/1), so the report shows what its snapshot holds.
  defp build_report(conn) do
    case TenantDatabase.read_only(conn, &PolicyEvalLoader.read/1) do
      {:ok, input} ->
        {:ok, PolicyEvalReport.build(input)}

      {:error, reason} ->
        log_warning("TenantInfoPolicyEvalFailed", reason)
        message = if is_exception(reason), do: Exception.message(reason), else: inspect(reason)
        {:error, "Failed to read the policies: #{message}"}
    end
  end

  @doc "The Policies card. `state` is `nil` until the first read returns, then what `read/1` returned."
  attr :state, :any, required: true

  def card(assigns) do
    ~H"""
    <.section id="policy-eval" title="Policies" flush={false}>
      <.lazy_section
        :let={report}
        id="policy-eval-section"
        event="load_policy_eval"
        title="Policies on realtime.messages"
        count={&length(&1.policies)}
        state={@state}
      >
        <.report report={report} />
      </.lazy_section>
    </.section>
    """
  end

  attr :report, :map, required: true

  defp report(assigns) do
    ~H"""
    <h6 class="mt-3 mb-1">Decisions</h6>
    <.table id="policy-eval-decisions" class="table table-sm mb-3" rows={@report.decisions}>
      <:col :let={decision} label="role">{decision.role}</:col>
      <:col :let={decision} label="operation">{decision.operation}</:col>
      <:col :let={decision} label="outcome"><.outcome outcome={decision.outcome} /></:col>
    </.table>

    <h6 class="mb-1">Table and roles</h6>
    <table class="table table-sm mb-3" id="policy-eval-roles">
      <thead>
        <tr><th>role</th><th>bypasses RLS</th><th>SELECT</th><th>INSERT</th></tr>
      </thead>
      <tbody>
        <tr>
          <td>realtime.messages</td>
          <td colspan="3">
            row level security <.flag value={@report.rls_enabled} expected={true} yes="enabled" no="disabled" />,
            <.flag value={@report.rls_forced} expected={false} yes="forced" no="not forced" />
          </td>
        </tr>
        <tr :for={%{name: name, info: info} <- @report.roles}>
          <td>{name}</td>
          <%= if info do %>
            <td><.flag value={info.bypass_rls} expected={false} /></td>
            <td><.flag value={info.select} expected={true} /></td>
            <td><.flag value={info.insert} expected={true} /></td>
          <% else %>
            <td colspan="3" class="text-danger">does not exist</td>
          <% end %>
        </tr>
      </tbody>
    </table>

    <h6 class="mb-1">Known functions</h6>
    <p class="text-muted small mb-1">
      policy_eval inlines a call to one of these functions only if its definition is LANGUAGE sql, STABLE, not SECURITY
      DEFINER, without SET, and its body is a known one. A call to any other function is unsupported.
    </p>
    <.table id="policy-eval-functions" class="table table-sm mb-3" rows={@report.functions}>
      <:col :let={function} label="function" code>{function.name}()</:col>
      <:col :let={function} label="status"><.function_status status={function.status} /></:col>
      <:col :let={function} label="definition">
        <.definition :for={definition <- function.definitions} definition={definition} />
      </:col>
    </.table>

    <h6 class="mb-1">Policies</h6>
    <.table id="policy-eval-policies" rows={@report.policies} empty="None">
      <:col :let={policy} label="name">{policy.name}</:col>
      <:col :let={policy} label="command">
        {policy.command}
        <div :if={!policy.used} class="text-muted small">not used by Realtime</div>
      </:col>
      <:col :let={policy} label="type">{if policy.permissive, do: "permissive", else: "restrictive"}</:col>
      <:col :let={policy} label="roles">
        <div :for={role <- policy.roles}>
          <%= if role in policy.unmodelled_roles do %>
            <span class="text-danger" title="policy_eval does not model this role">{role} (not modelled)</span>
          <% else %>
            {role}
          <% end %>
        </div>
      </:col>
      <:col :let={policy} label="USING"><.expression expression={policy.using} /></:col>
      <:col :let={policy} label="WITH CHECK"><.expression expression={policy.with_check} /></:col>
    </.table>
    """
  end

  attr :outcome, :any, required: true

  defp outcome(%{outcome: {:always_fallback, {_category, reason} = part}} = assigns) do
    assigns = assign(assigns, description: PolicyEvalReport.describe(reason), part: part)

    ~H"""
    <span class="text-danger">always falls back:</span> {@description}
    <.unsupported parts={[@part]} />
    """
  end

  defp outcome(%{outcome: :no_permissive_policy} = assigns) do
    ~H"""
    always denied: no permissive policy applies
    """
  end

  defp outcome(%{outcome: {:evaluates, names, unsupported}} = assigns) do
    assigns = assign(assigns, names: Enum.join(names, ", "), unsupported: unsupported)

    ~H"""
    evaluates {@names}
    <div :if={@unsupported == []} class="text-success small">no unsupported parts</div>
    <div :if={@unsupported != []} class="small">falls back when the evaluation reaches:</div>
    <.unsupported parts={@unsupported} />
    """
  end

  attr :expression, :any, required: true, doc: "`nil`, or `%{text: text, unsupported: parts}`"

  defp expression(%{expression: nil} = assigns) do
    ~H"""
    <span class="text-muted">none</span>
    """
  end

  defp expression(assigns) do
    ~H"""
    <div class="text-monospace small" style="white-space: pre-wrap; overflow-wrap: anywhere;">{@expression.text}</div>
    <div :if={@expression.unsupported == []} class="text-success small">supported</div>
    <.unsupported parts={@expression.unsupported} />
    """
  end

  attr :parts, :list, required: true

  defp unsupported(assigns) do
    ~H"""
    <div :for={{category, reason} <- @parts} class="text-danger text-monospace small">
      {category}: {inspect(reason)}
    </div>
    """
  end

  attr :status, :atom, required: true

  defp function_status(%{status: :known} = assigns) do
    ~H"""
    known
    """
  end

  defp function_status(assigns) do
    ~H"""
    <span class="text-danger">{@status |> Atom.to_string() |> String.replace("_", " ")}</span>
    """
  end

  attr :definition, :map, required: true

  defp definition(assigns) do
    ~H"""
    <div class="small text-muted">
      language {@definition.language}, volatility {@definition.volatility},
      security definer {@definition.security_definer}, config {inspect(@definition.config)},
      returns {@definition.return_type}
    </div>
    <pre class="small mb-1" style="white-space: pre-wrap; overflow-wrap: anywhere;">{@definition.source}</pre>
    """
  end
end
