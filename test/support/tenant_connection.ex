defmodule TenantConnection do
  @moduledoc """
  Boilerplate code to handle Realtime.Tenants.Connect during tests
  """
  alias Realtime.Api.Tenant

  def connect_child_spec(%Tenant{external_id: external_id}, connect_child_spec \\ []) do
    {Realtime.Tenants.Connect, Keyword.merge(connect_child_spec, tenant_id: external_id)}
  end

  def tenant_connection(tenant) do
    Realtime.Tenants.Connect.get_status(tenant.external_id)
  end
end
