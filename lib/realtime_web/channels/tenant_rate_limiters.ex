defmodule RealtimeWeb.TenantRateLimiters do
  @moduledoc """
  Rate limiters for tenants.
  """
  alias Realtime.FeatureFlags
  alias Realtime.UsersCounter
  alias Realtime.Tenants.NodeJoinBudget
  alias Realtime.Api.Tenant

  @node_join_budget_flag "node_join_budget"

  @spec check_tenant(Realtime.Api.Tenant.t()) ::
          :ok | {:error, :too_many_connections | :too_many_node_joins}
  def check_tenant(tenant) do
    with :ok <- max_concurrent_users_check(tenant) do
      node_join_budget_check(tenant)
    end
  end

  defp max_concurrent_users_check(%Tenant{max_concurrent_users: max_conn_users, external_id: external_id}) do
    total_conn_users = UsersCounter.tenant_users(external_id)

    if total_conn_users < max_conn_users,
      do: :ok,
      else: {:error, :too_many_connections}
  end

  defp node_join_budget_check(%Tenant{external_id: external_id} = tenant) do
    if FeatureFlags.enabled?(@node_join_budget_flag, external_id) and NodeJoinBudget.exhausted?(tenant),
      do: {:error, :too_many_node_joins},
      else: :ok
  end
end
