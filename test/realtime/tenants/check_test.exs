defmodule Realtime.Tenants.CheckTest do
  use Realtime.DataCase
  alias Realtime.Tenants.Check

  setup do
    Registry.start_link(
      keys: :unique,
      name: Realtime.Registry.Tenant
    )

    %{tenant: tenant_fixture()}
  end

  describe "connection_status/1" do
    test "returns :ok when tenant is reachable", %{tenant: tenant} do
      start_supervised!({Check, %Check{tenant_id: tenant.external_id}})
      :ok = Check.connection_status(tenant.external_id)
      assert true
    end
  end
end
