defmodule Realtime.Presence.RollcallBackendTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Phoenix.Socket.Broadcast
  alias Realtime.Presence.RollcallBackend

  setup :set_mimic_from_context

  setup do
    id = System.unique_integer([:positive])
    tenant = "tenant-#{id}"

    Realtime.FeatureFlags
    |> stub(:enabled?, fn flag, _tenant -> flag == "presence_rollcall_primary" end)
    |> allow(self(), fn -> Rollcall.Tracker.whereis(Realtime.Presence.Rollcall, tenant) end)

    {:ok, tenant: tenant, topic: "realtime:rollcall-presence-#{id}"}
  end

  test "track/6 adds the entry to the state that list/2 returns", %{tenant: tenant, topic: topic} do
    assert {:ok, :track, ref} = RollcallBackend.track(client(), tenant, topic, "alice", %{"status" => "online"})

    assert RollcallBackend.list(tenant, topic) == %{
             "alice" => %{metas: [%{"status" => "online", phx_ref: ref}]}
           }
  end

  test "track/6 updates the entry when the pid tracks the key again", %{tenant: tenant, topic: topic} do
    pid = client()
    {:ok, :track, first} = RollcallBackend.track(pid, tenant, topic, "alice", %{"status" => "online"})

    assert {:ok, _action, second} = RollcallBackend.track(pid, tenant, topic, "alice", %{"status" => "away"})

    assert RollcallBackend.list(tenant, topic) == %{
             "alice" => %{metas: [%{"status" => "away", phx_ref: second, phx_ref_prev: first}]}
           }
  end

  test "track/6 uses the ref that the caller passes", %{tenant: tenant, topic: topic} do
    assert {:ok, :track, "caller-ref"} = RollcallBackend.track(client(), tenant, topic, "alice", %{}, ref: "caller-ref")

    assert RollcallBackend.list(tenant, topic) == %{"alice" => %{metas: [%{phx_ref: "caller-ref"}]}}
  end

  test "untrack/4 removes the entry", %{tenant: tenant, topic: topic} do
    pid = client()
    {:ok, :track, _ref} = RollcallBackend.track(pid, tenant, topic, "alice", %{})

    assert :ok = RollcallBackend.untrack(pid, tenant, topic, "alice")

    assert RollcallBackend.list(tenant, topic) == %{}
  end

  test "list/2 does not return the entries of another tenant", %{tenant: tenant, topic: topic} do
    {:ok, :track, _ref} = RollcallBackend.track(client(), tenant, topic, "alice", %{})

    assert RollcallBackend.list("other-#{tenant}", topic) == %{}
  end

  test "publishes the presence_diff of a track and an untrack on the topic", %{tenant: tenant, topic: topic} do
    :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, topic)
    pid = client()

    {:ok, :track, ref} = RollcallBackend.track(pid, tenant, topic, "alice", %{"status" => "online"})

    assert_receive %Broadcast{
      topic: ^topic,
      event: "presence_diff",
      payload: %{joins: %{"alice" => %{metas: [%{"status" => "online", phx_ref: ^ref}]}}, leaves: leaves}
    }

    assert leaves == %{}

    :ok = RollcallBackend.untrack(pid, tenant, topic, "alice")

    assert_receive %Broadcast{
      topic: ^topic,
      event: "presence_diff",
      payload: %{joins: joins, leaves: %{"alice" => %{metas: [%{phx_ref: ^ref}]}}}
    }

    assert joins == %{}
  end

  # A process that stays alive until the test ends. Rollcall removes its entries after that.
  defp client, do: spawn_link(fn -> Process.sleep(:infinity) end)
end
