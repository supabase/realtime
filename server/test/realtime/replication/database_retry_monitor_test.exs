defmodule Realtime.DatabaseRetryMonitorTest do
  use ExUnit.Case, async: true

  alias Realtime.DatabaseRetryMonitor

  @child_spec {DatabaseRetryMonitor, [name: __MODULE__]}

  test "Realtime.DatabaseRetryMonitor initial state is an empty list" do
    pid = start_supervised!(@child_spec)

    assert :sys.get_state(pid) == []
  end

  test "Realtime.DatabaseRetryMonitor.get_delay/1 returns integers" do
    pid = start_supervised!(@child_spec)

    assert DatabaseRetryMonitor.get_delay(pid) == 0

    state = :sys.get_state(pid)

    assert is_list(state)
    refute Enum.empty?(state)
    assert Enum.all?(state, &(is_integer(&1) and &1 > 0))
    assert DatabaseRetryMonitor.get_delay(pid) == List.first(state)
  end

  test "Realtime.DatabaseRetryMonitor.reset_delay/1 sets state to an empty list" do
    pid = start_supervised!(@child_spec)

    # populate state with delays
    GenServer.call(pid, :delay)

    refute Enum.empty?(:sys.get_state(pid))

    DatabaseRetryMonitor.reset_delay(pid)

    assert :sys.get_state(pid) == []
  end

  test "Realtime.DatabaseRetryMonitor.handle_call/3 :: :delay when state is not empty" do
    state = [492, 1023, 1992]

    response = DatabaseRetryMonitor.handle_call(:delay, nil, state)

    assert {:reply, 492, [1023, 1992]} = response
  end

  test "Realtime.DatabaseRetryMonitor.handle_call/3 :: :delay when state is empty" do
    state = []

    {_, reply, new_state} = DatabaseRetryMonitor.handle_call(:delay, nil, state)

    assert reply == 0
    assert is_list(new_state)
    refute Enum.empty?(new_state)
    assert Enum.all?(new_state, &(is_integer(&1) and &1 > 0))
  end

  test "Realtime.DatabaseRetryMonitor.handle_call/3 :: :reset" do
    response = DatabaseRetryMonitor.handle_call(:reset, nil, nil)

    assert {:reply, :ok, []} = response
  end
end
