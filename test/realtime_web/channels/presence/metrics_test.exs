defmodule RealtimeWeb.Presence.MetricsTest do
  use ExUnit.Case, async: true

  alias Phoenix.Socket.Broadcast
  alias RealtimeWeb.Presence.Metrics

  describe "stamp/1" do
    test "adds an envelope with the current time in ms and this node's short id" do
      before = System.system_time(:millisecond)
      stamped = Metrics.stamp(%{"name" => "alice"})
      after_ = System.system_time(:millisecond)

      assert %{_rt: %{ts: ts, node: node}} = stamped
      assert is_integer(ts) and ts >= before and ts <= after_
      assert node == Realtime.Nodes.short_node_id_from_name(node())
    end

    test "leaves the user payload untouched" do
      payload = %{"name" => "alice", "nested" => %{"a" => 1}}

      assert Map.delete(Metrics.stamp(payload), :_rt) == payload
    end

    test "passes a non-map payload through for validation to reject" do
      assert Metrics.stamp("not a map") == "not a map"
      assert Metrics.stamp(nil) == nil
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

      assert Metrics.strip_diff(diff) == %Broadcast{
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

    test "a diff without an envelope comes back equal" do
      diff = %Broadcast{
        event: "presence_diff",
        payload: %{joins: %{"bob" => %{metas: [%{"name" => "bob", :phx_ref => "b1"}]}}, leaves: %{}}
      }

      assert Metrics.strip_diff(diff) == diff
    end

    test "does not add joins or leaves keys that were not there, and tolerates empty metas" do
      diff = %Broadcast{event: "presence_diff", payload: %{joins: %{"bob" => %{metas: []}}}}

      assert Metrics.strip_diff(diff) == diff
    end

    test "any other broadcast passes through untouched" do
      msg = %Broadcast{event: "broadcast", payload: %{"_rt" => "not ours", :_rt => "nor this"}}

      assert Metrics.strip_diff(msg) == msg
    end
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
