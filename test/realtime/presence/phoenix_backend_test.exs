defmodule Realtime.Presence.PhoenixBackendTest do
  use ExUnit.Case, async: true

  alias Realtime.Presence.PhoenixBackend

  setup do
    id = System.unique_integer([:positive])
    {:ok, topic: "realtime:phoenix-presence-#{id}"}
  end

  test "track/4 adds the entry to the state that list/1 returns", %{topic: topic} do
    assert {:ok, :track, ref} = PhoenixBackend.track(client(), topic, "alice", %{"status" => "online"})

    assert PhoenixBackend.list(topic) == %{
             "alice" => %{metas: [%{"status" => "online", phx_ref: ref}]}
           }
  end

  test "track/4 updates the entry when the pid tracks the key again", %{topic: topic} do
    pid = client()
    {:ok, :track, first} = PhoenixBackend.track(pid, topic, "alice", %{"status" => "online"})

    assert {:ok, :update, second} = PhoenixBackend.track(pid, topic, "alice", %{"status" => "away"})

    assert PhoenixBackend.list(topic) == %{
             "alice" => %{metas: [%{"status" => "away", phx_ref: second, phx_ref_prev: first}]}
           }
  end

  test "untrack/3 removes the entry", %{topic: topic} do
    pid = client()
    {:ok, :track, _ref} = PhoenixBackend.track(pid, topic, "alice", %{})

    assert :ok = PhoenixBackend.untrack(pid, topic, "alice")

    assert PhoenixBackend.list(topic) == %{}
  end

  # A process that stays alive until the test ends. Presence removes its entries after that.
  defp client, do: spawn_link(fn -> Process.sleep(:infinity) end)
end
