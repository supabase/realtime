defmodule Realtime.Tenants.CacheSupervisorTest do
  use Realtime.DataCase, async: false

  alias Realtime.Api.Tenant
  alias Realtime.Tenants.Cache

  setup do
    %{tenant: tenant_fixture()}
  end

  test "invalidates cache on PubSub message", %{tenant: tenant} do
    external_id = tenant.external_id
    assert %Tenant{suspend: false} = Cache.get_tenant_by_external_id(external_id)

    # Update a tenant
    tenant |> Tenant.changeset(%{suspend: true}) |> Realtime.Repo.update!()

    # Cache showing old value
    assert %Tenant{suspend: false} = Cache.get_tenant_by_external_id(external_id)

    # PubSub message
    Phoenix.PubSub.broadcast(
      Realtime.PubSub,
      "realtime:operations:invalidate_cache",
      {:suspend_tenant, external_id}
    )

    :timer.sleep(500)
    assert %Tenant{suspend: true} = Cache.get_tenant_by_external_id(external_id)
  end
end
