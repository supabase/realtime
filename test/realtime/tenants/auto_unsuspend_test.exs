defmodule Realtime.Tenants.AutoUnsuspendTest do
  use Realtime.DataCase, async: false

  alias Realtime.Tenants.AutoUnsuspend

  describe "perform_check/0" do
    test "unsuspends tenants whose auto_unsuspend_at is in the past" do
      past = DateTime.add(DateTime.utc_now(), -1, :minute)
      tenant = tenant_fixture(%{suspend: true, auto_unsuspend_at: past})

      AutoUnsuspend.perform_check()

      updated = Repo.reload!(tenant)
      assert updated.suspend == false
      assert updated.auto_unsuspend_at == nil
    end

    test "does not touch tenants whose auto_unsuspend_at is in the future" do
      future = DateTime.add(DateTime.utc_now(), 10, :minute)
      tenant = tenant_fixture(%{suspend: true, auto_unsuspend_at: future})

      AutoUnsuspend.perform_check()

      updated = Repo.reload!(tenant)
      assert updated.suspend == true
      assert updated.auto_unsuspend_at != nil
    end

    test "does not touch manually suspended tenants (auto_unsuspend_at is nil)" do
      tenant = tenant_fixture(%{suspend: true})

      AutoUnsuspend.perform_check()

      updated = Repo.reload!(tenant)
      assert updated.suspend == true
    end
  end
end
