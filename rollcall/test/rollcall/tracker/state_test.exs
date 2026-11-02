defmodule Rollcall.Tracker.StateTest do
  use ExUnit.Case, async: true

  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Entry
  alias Rollcall.Tracker.Local
  alias Rollcall.Tracker.Peer
  alias Rollcall.Tracker.State

  @incarnation 1_000

  setup do
    state = %State{
      scope: "scope",
      incarnation: @incarnation,
      empty_grace: 5_000,
      local: Local.new(),
      silence_threshold: 10,
      heartbeat_period: :manual,
      transport_module: Rollcall.Transport.Null,
      transport_state: nil
    }

    %{state: state}
  end

  describe "apply_changes/3" do
    test "sets local and increases the version when the changes are not empty", %{state: state} do
      {changes, local} = Local.track(state.local, self(), "partition", "key", %{}, make_ref())

      state = State.apply_changes(state, local, changes)

      assert state.local == local
      assert state.version == 1
    end

    test "increases the version by one for each change", %{state: state} do
      {changes_1, local_1} = Local.track(state.local, self(), "partition", "key_1", %{}, make_ref())
      {changes_2, local_2} = Local.track(local_1, self(), "partition", "key_2", %{}, make_ref())

      state =
        state
        |> State.apply_changes(local_1, changes_1)
        |> State.apply_changes(local_2, changes_2)

      assert state.version == 2
    end

    test "sets local and keeps the version when the changes are empty", %{state: state} do
      {_changes, local} = Local.track(state.local, self(), "partition", "key", %{}, make_ref())

      state = State.apply_changes(state, local, Changes.new())

      assert state.local == local
      assert state.version == 0
    end

    test "counts a change that only has leaves", %{state: state} do
      entry = Entry.new(self(), "partition", "key", %{}, make_ref())

      state = State.apply_changes(state, state.local, Changes.new([], [entry]))

      assert state.version == 1
    end
  end

  describe "peer/2 and put_peer/3" do
    test "peer/2 returns nil for a node that sent no message", %{state: state} do
      assert State.peer(state, :a@host) == nil
    end

    test "peer/2 returns the record that put_peer/3 set", %{state: state} do
      peer = %Peer{silent_ticks: 2}

      state = State.put_peer(state, :a@host, peer)

      assert State.peer(state, :a@host) == peer
    end

    test "put_peer/3 replaces the record of the node", %{state: state} do
      state =
        state
        |> State.put_peer(:a@host, %Peer{silent_ticks: 2})
        |> State.put_peer(:a@host, %Peer{silent_ticks: 0})

      assert State.peer(state, :a@host) == %Peer{silent_ticks: 0}
    end

    test "put_peer/3 keeps the records of the other nodes", %{state: state} do
      state =
        state
        |> State.put_peer(:a@host, %Peer{silent_ticks: 1})
        |> State.put_peer(:b@host, %Peer{silent_ticks: 2})

      assert State.peer(state, :a@host) == %Peer{silent_ticks: 1}
      assert State.peer(state, :b@host) == %Peer{silent_ticks: 2}
    end

    test "put_peer/3 does not change the other fields", %{state: state} do
      assert %{State.put_peer(state, :a@host, %Peer{}) | peers: %{}} == state
    end
  end

  describe "inspect_view/1" do
    test "returns the fields that have a meaning outside the process", %{state: state} do
      peer = %Peer{silent_ticks: 2}
      state = %{state | version: 3} |> State.put_peer(:a@host, peer)

      assert State.inspect_view(state) == %{
               scope: "scope",
               version: 3,
               incarnation: @incarnation,
               local: state.local,
               peers: %{a@host: peer}
             }
    end

    test "leaves out the timer, the monitors and the transport", %{state: state} do
      view = State.inspect_view(state)

      refute Map.has_key?(view, :empty_timer)
      refute Map.has_key?(view, :monitors)
      refute Map.has_key?(view, :transport_module)
      refute Map.has_key?(view, :transport_state)
    end
  end

  describe "current_stamp/1" do
    test "has the incarnation and the version", %{state: state} do
      assert State.current_stamp(%{state | version: 4}) == {:stamp, @incarnation, 4}
    end
  end

  describe "goodbye_stamp/1" do
    test "has the incarnation and the version plus one", %{state: state} do
      assert State.goodbye_stamp(%{state | version: 4}) == {:stamp, @incarnation, 5}
    end

    test "is newer than the current stamp at version 0", %{state: state} do
      assert State.goodbye_stamp(state) == {:stamp, @incarnation, 1}
    end
  end
end
