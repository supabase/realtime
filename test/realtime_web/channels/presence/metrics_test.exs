defmodule RealtimeWeb.Presence.MetricsTest do
  use ExUnit.Case, async: true
  use Mimic

  setup :set_mimic_from_context

  alias Phoenix.Socket.Broadcast
  alias Realtime.FeatureFlags
  alias RealtimeWeb.Presence.Metrics
  alias RealtimeWeb.Presence.Metrics.Envelope

  @tenant "tenant-123"

  describe "stamp/2" do
    test "adds an envelope with the current time in ms and this node's short id when sampled" do
      stub(FeatureFlags, :enabled?, fn "presence_latency_metric", @tenant -> true end)

      before = System.system_time(:millisecond)
      stamped = Metrics.stamp(%{"name" => "alice"}, @tenant)
      after_ = System.system_time(:millisecond)

      assert %{_rt: %{ts: ts, node: node}} = stamped
      assert is_integer(ts) and ts >= before and ts <= after_
      assert node == Realtime.Nodes.short_node_id_from_name(node())
    end

    test "leaves the user payload untouched" do
      stub(FeatureFlags, :enabled?, fn _, _ -> true end)
      payload = %{"name" => "alice", "nested" => %{"a" => 1}}

      assert Map.delete(Metrics.stamp(payload, @tenant), :_rt) == payload
    end

    test "returns the payload untouched when the feature flag is off for the tenant" do
      stub(FeatureFlags, :enabled?, fn "presence_latency_metric", @tenant -> false end)
      payload = %{"name" => "alice"}

      assert Metrics.stamp(payload, @tenant) == payload
    end

    test "passes a non-map payload through for validation to reject" do
      reject(&FeatureFlags.enabled?/2)

      assert Metrics.stamp("not a map", @tenant) == "not a map"
      assert Metrics.stamp(nil, @tenant) == nil
    end
  end

  describe "sample?/2" do
    test "never samples at rate 0, without consulting the feature flag" do
      reject(&FeatureFlags.enabled?/2)

      refute Enum.any?(1..100, fn _ -> Metrics.sample?(@tenant, 0.0) end)
    end

    test "always samples at rate 1 when the flag is on" do
      stub(FeatureFlags, :enabled?, fn "presence_latency_metric", @tenant -> true end)

      assert Enum.all?(1..100, fn _ -> Metrics.sample?(@tenant, 1.0) end)
    end

    test "never samples when the flag is off, whatever the rate" do
      stub(FeatureFlags, :enabled?, fn "presence_latency_metric", @tenant -> false end)

      refute Enum.any?(1..100, fn _ -> Metrics.sample?(@tenant, 1.0) end)
    end
  end

  describe "strip_diff/1" do
    test "removes the envelope from every join and leave meta, keeping everything else" do
      envelope = %{ts: 1, node: "n1"}

      diff = %Broadcast{
        topic: "realtime:room",
        event: "presence_diff",
        payload: %{
          joins: %{
            "alice" => %{
              metas: [
                %{"name" => "alice", :phx_ref => "a1", :phx_ref_prev => "a0", :_rt => envelope},
                %{"name" => "alice", :phx_ref => "a2"}
              ]
            }
          },
          leaves: %{"alice" => %{metas: [%{"name" => "alice", :phx_ref => "a0", :_rt => envelope}]}}
        }
      }

      assert {stripped, _envelopes} = Metrics.strip_diff(diff)

      assert stripped == %Broadcast{
               topic: "realtime:room",
               event: "presence_diff",
               payload: %{
                 joins: %{
                   "alice" => %{
                     metas: [
                       %{"name" => "alice", :phx_ref => "a1", :phx_ref_prev => "a0"},
                       %{"name" => "alice", :phx_ref => "a2"}
                     ]
                   }
                 },
                 leaves: %{"alice" => %{metas: [%{"name" => "alice", :phx_ref => "a0"}]}}
               }
             }
    end

    test "returns one envelope per stamped join meta, naming the action, and none for leaves" do
      diff = %Broadcast{
        event: "presence_diff",
        payload: %{
          joins: %{
            # An update: the meta replaces a previous one.
            "alice" => %{
              metas: [
                %{"name" => "alice", :phx_ref => "a1", :phx_ref_prev => "a0", :_rt => %{ts: 1, node: "n1"}},
                %{"name" => "alice", :phx_ref => "a2"}
              ]
            },
            # A first track.
            "bob" => %{metas: [%{"name" => "bob", :phx_ref => "b1", :_rt => %{ts: 2, node: "n2"}}]}
          },
          # The leave carries the envelope from when it was tracked; it is stripped but never measured.
          leaves: %{"alice" => %{metas: [%{"name" => "alice", :phx_ref => "a0", :_rt => %{ts: 0, node: "n1"}}]}}
        }
      }

      assert {_stripped, envelopes} = Metrics.strip_diff(diff)

      assert Enum.sort_by(envelopes, & &1.ts) == [
               %Envelope{ts: 1, node: "n1", action: :update},
               %Envelope{ts: 2, node: "n2", action: :track}
             ]
    end

    test "a diff without an envelope comes back as is, with no envelopes" do
      diff = %Broadcast{
        event: "presence_diff",
        payload: %{joins: %{"bob" => %{metas: [%{"name" => "bob", :phx_ref => "b1"}]}}, leaves: %{}}
      }

      assert {^diff, []} = Metrics.strip_diff(diff)
    end

    test "does not add joins or leaves keys that were not there, and tolerates empty metas" do
      diff = %Broadcast{event: "presence_diff", payload: %{joins: %{"bob" => %{metas: []}}}}

      assert {^diff, []} = Metrics.strip_diff(diff)
    end

    test "a diff with only leaves is stripped and yields no envelopes" do
      diff = %Broadcast{
        event: "presence_diff",
        payload: %{leaves: %{"bob" => %{metas: [%{"name" => "bob", :phx_ref => "b1", :_rt => %{ts: 1, node: "n1"}}]}}}
      }

      assert {stripped, []} = Metrics.strip_diff(diff)
      assert stripped.payload == %{leaves: %{"bob" => %{metas: [%{"name" => "bob", :phx_ref => "b1"}]}}}
    end

    test "any other broadcast passes through untouched" do
      msg = %Broadcast{event: "broadcast", payload: %{"_rt" => "not ours", :_rt => "nor this"}}

      assert {^msg, []} = Metrics.strip_diff(msg)
    end
  end

  describe "record/2" do
    setup do
      tenant = "tenant-#{System.unique_integer([:positive])}"
      attach_telemetry(tenant)

      context = %{tenant: tenant, path: :fastlane, implementation: :phoenix, now: 10_000, node: "n1"}

      %{tenant: tenant, context: context}
    end

    test "emits one latency observation per envelope, tagged with the context", %{
      tenant: tenant,
      context: context
    } do
      envelopes = [
        %Envelope{ts: 9_990, node: "n1", action: :track},
        %Envelope{ts: 8_500, node: "n2", action: :update}
      ]

      assert :ok = Metrics.record(envelopes, context)

      assert_receive {:telemetry, [:realtime, :presence, :notify, :latency], %{latency: 10},
                      %{tenant: ^tenant, action: :track, origin: :local, path: :fastlane, implementation: :phoenix}}

      assert_receive {:telemetry, [:realtime, :presence, :notify, :latency], %{latency: 1_500},
                      %{tenant: ^tenant, action: :update, origin: :remote, path: :fastlane, implementation: :phoenix}}

      refute_receive {:telemetry, _, _, _}
    end

    test "carries the path through", %{tenant: tenant, context: context} do
      assert :ok = Metrics.record([%Envelope{ts: 9_999, node: "n1", action: :track}], %{context | path: :channel})

      assert_receive {:telemetry, [:realtime, :presence, :notify, :latency], _, %{tenant: ^tenant, path: :channel}}
    end

    test "a negative latency is discarded as clock skew rather than recorded", %{tenant: tenant, context: context} do
      assert :ok = Metrics.record([%Envelope{ts: 10_005, node: "n2", action: :track}], context)

      assert_receive {:telemetry, [:realtime, :presence, :notify, :discarded], _, %{tenant: ^tenant, reason: :negative}}
      refute_receive {:telemetry, [:realtime, :presence, :notify, :latency], _, _}
    end

    test "anything older than the stale bound is discarded, the bound itself is not", %{
      tenant: tenant,
      context: context
    } do
      assert :ok = Metrics.record([%Envelope{ts: 10_000 - 30_001, node: "n2", action: :track}], context)

      assert_receive {:telemetry, [:realtime, :presence, :notify, :discarded], _, %{tenant: ^tenant, reason: :stale}}
      refute_receive {:telemetry, [:realtime, :presence, :notify, :latency], _, _}

      assert :ok = Metrics.record([%Envelope{ts: 10_000 - 30_000, node: "n2", action: :track}], context)

      assert_receive {:telemetry, [:realtime, :presence, :notify, :latency], %{latency: 30_000}, %{tenant: ^tenant}}
    end

    test "records nothing for no envelopes", %{context: context} do
      assert :ok = Metrics.record([], context)

      refute_receive {:telemetry, _, _, _}
    end
  end

  defp attach_telemetry(tenant) do
    id = {__MODULE__, tenant}

    :telemetry.attach_many(
      id,
      [[:realtime, :presence, :notify, :latency], [:realtime, :presence, :notify, :discarded]],
      &__MODULE__.handle_telemetry/4,
      %{pid: self(), tenant: tenant}
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  def handle_telemetry(event, measurements, metadata, %{pid: pid, tenant: tenant}) do
    if metadata[:tenant] == tenant, do: send(pid, {:telemetry, event, measurements, metadata})
  end

  describe "strip_state/1" do
    test "removes the envelope from every meta in a grouped presence list" do
      state = %{
        "alice" => %{metas: [%{"name" => "alice", :phx_ref => "a1", :_rt => %{ts: 1, node: "n1"}}]},
        "bob" => %{metas: [%{"name" => "bob", :phx_ref => "b1"}]}
      }

      assert Metrics.strip_state(state) == %{
               "alice" => %{metas: [%{"name" => "alice", :phx_ref => "a1"}]},
               "bob" => %{metas: [%{"name" => "bob", :phx_ref => "b1"}]}
             }
    end

    test "an empty list stays empty" do
      assert Metrics.strip_state(%{}) == %{}
    end
  end
end
