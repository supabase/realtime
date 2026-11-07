defmodule Realtime.Presence.EncoderTest do
  use ExUnit.Case, async: true

  alias Phoenix.Socket.Broadcast
  alias Realtime.Presence.Encoder
  alias RealtimeWeb.Presence.Metrics

  defp sorted(%{metas: metas} = presence), do: %{presence | metas: Enum.sort_by(metas, & &1.phx_ref)}

  defp sorted_state(state), do: Map.new(state, fn {key, presence} -> {key, sorted(presence)} end)

  defp sorted_diff(%{joins: joins, leaves: leaves}), do: %{joins: sorted_state(joins), leaves: sorted_state(leaves)}

  describe "state/1" do
    test "returns an empty map for no entries" do
      assert Encoder.state([]) == %{}
    end

    test "returns the meta of an entry under its key with the ref in phx_ref" do
      assert Encoder.state([{"r1", "alice", %{"status" => "online"}}]) == %{
               "alice" => %{metas: [%{"status" => "online", phx_ref: "r1"}]}
             }
    end

    test "groups the entries of one key into one list of metas" do
      state = Encoder.state([{"r1", "alice", %{"device" => "phone"}}, {"r2", "alice", %{"device" => "laptop"}}])

      assert sorted_state(state) == %{
               "alice" => %{
                 metas: [%{"device" => "phone", phx_ref: "r1"}, %{"device" => "laptop", phx_ref: "r2"}]
               }
             }
    end

    test "keeps the entries of different keys apart" do
      state = Encoder.state([{"r1", "alice", %{}}, {"r2", "bob", %{}}])

      assert state == %{
               "alice" => %{metas: [%{phx_ref: "r1"}]},
               "bob" => %{metas: [%{phx_ref: "r2"}]}
             }
    end

    test "keeps the keys and the values of the meta as they are" do
      meta = %{"name" => "alice", "nested" => %{"tags" => ["a", "b"]}, :atom_key => 1}

      assert %{"alice" => %{metas: [encoded]}} = Encoder.state([{"r1", "alice", meta}])
      assert Map.delete(encoded, :phx_ref) == meta
    end

    test "turns the previous ref of an updated entry into phx_ref_prev" do
      state = Encoder.state([{"r2", "alice", %{"n" => 2, rc_prev_ref: "r1"}}])

      assert state == %{"alice" => %{metas: [%{"n" => 2, phx_ref: "r2", phx_ref_prev: "r1"}]}}
    end

    test "adds no phx_ref_prev to an entry that was not updated" do
      assert %{"alice" => %{metas: [meta]}} = Encoder.state([{"r1", "alice", %{}}])
      refute Map.has_key?(meta, :phx_ref_prev)
      refute Map.has_key?(meta, :rc_prev_ref)
    end

    test "keeps a string key phx_ref of the user next to the atom key" do
      assert %{"alice" => %{metas: [meta]}} = Encoder.state([{"r1", "alice", %{"phx_ref" => "mine"}}])
      assert meta == %{"phx_ref" => "mine", phx_ref: "r1"}
    end

    test "overwrites an atom key phx_ref in the meta with the ref" do
      assert %{"alice" => %{metas: [meta]}} = Encoder.state([{"r1", "alice", %{phx_ref: "mine"}}])
      assert meta == %{phx_ref: "r1"}
    end

    test "gives a payload that Metrics.strip_state strips of the envelope" do
      envelope = %{ts: 1, node: "n1"}
      state = Encoder.state([{"r1", "alice", %{"name" => "alice", _rt: envelope}}])

      assert Metrics.strip_state(state) == %{"alice" => %{metas: [%{"name" => "alice", phx_ref: "r1"}]}}
    end
  end

  describe "diff/1" do
    test "returns empty joins and empty leaves for an empty diff" do
      assert Encoder.diff({[], []}) == %{joins: %{}, leaves: %{}}
    end

    test "groups the joins by key" do
      diff = Encoder.diff({[{"r1", "alice", %{"n" => 1}}, {"r2", "bob", %{}}], []})

      assert diff == %{
               joins: %{
                 "alice" => %{metas: [%{"n" => 1, phx_ref: "r1"}]},
                 "bob" => %{metas: [%{phx_ref: "r2"}]}
               },
               leaves: %{}
             }
    end

    test "groups the leaves by key" do
      diff = Encoder.diff({[], [{"r1", "alice", %{"n" => 1}}]})

      assert diff == %{joins: %{}, leaves: %{"alice" => %{metas: [%{"n" => 1, phx_ref: "r1"}]}}}
    end

    test "groups the entries of one key on one side into one list of metas" do
      diff = Encoder.diff({[{"r1", "alice", %{}}, {"r2", "alice", %{}}], [{"r3", "alice", %{}}, {"r4", "alice", %{}}]})

      assert sorted_diff(diff) == %{
               joins: %{"alice" => %{metas: [%{phx_ref: "r1"}, %{phx_ref: "r2"}]}},
               leaves: %{"alice" => %{metas: [%{phx_ref: "r3"}, %{phx_ref: "r4"}]}}
             }
    end

    test "puts the new meta of an update in joins with phx_ref_prev, and the old meta in leaves" do
      diff = Encoder.diff({[{"r2", "alice", %{"n" => 2, rc_prev_ref: "r1"}}], [{"r1", "alice", %{"n" => 1}}]})

      assert diff == %{
               joins: %{"alice" => %{metas: [%{"n" => 2, phx_ref: "r2", phx_ref_prev: "r1"}]}},
               leaves: %{"alice" => %{metas: [%{"n" => 1, phx_ref: "r1"}]}}
             }
    end

    test "turns the previous ref of a left entry into phx_ref_prev" do
      diff = Encoder.diff({[], [{"r2", "alice", %{rc_prev_ref: "r1"}}]})

      assert diff.leaves == %{"alice" => %{metas: [%{phx_ref: "r2", phx_ref_prev: "r1"}]}}
    end

    test "gives a payload that Metrics.strip_diff strips of the envelope" do
      envelope = %{ts: 1, node: "n1"}
      diff = Encoder.diff({[{"r1", "alice", %{"name" => "alice", _rt: envelope}}], []})
      message = %Broadcast{topic: "t", event: "presence_diff", payload: diff}

      assert {%Broadcast{payload: payload}, [_envelope]} = Metrics.strip_diff(message)
      assert payload.joins == %{"alice" => %{metas: [%{"name" => "alice", phx_ref: "r1"}]}}
    end
  end
end
