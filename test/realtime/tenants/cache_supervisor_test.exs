defmodule Realtime.Tenants.CacheSupervisorTest do
  use Realtime.DataCase, async: false

  alias Realtime.Api.Tenant
  alias Realtime.Tenants.Cache

  setup do
    %{tenant: tenant_fixture()}
  end

  test "invalidates cache on PubSub message", %{tenant: %{external_id: external_id} = tenant} do
    assert %Tenant{suspend: false} = Cache.get_tenant_by_external_id(external_id)

    # Update a tenant
    tenant |> Tenant.changeset(%{suspend: true}) |> Realtime.Repo.update!()

    # Cache showing old value
    assert %Tenant{suspend: false} = Cache.get_tenant_by_external_id(external_id)

    # PubSub message
    Phoenix.PubSub.broadcast(Realtime.PubSub, "realtime:invalidate_cache", external_id)

    Process.sleep(300)
    assert %Tenant{suspend: true} = Cache.get_tenant_by_external_id(external_id)
  end
end
