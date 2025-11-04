defmodule RealtimeWeb.RealtimeChannel.TrackerTest do
  # It kills websockets when no channels are open
  # It can affect other tests
  use Realtime.DataCase, async: false
  alias RealtimeWeb.RealtimeChannel.Tracker

  setup do
    start_supervised!({Tracker, no_channel_timeout_in_ms: 50, egress_telemetry_interval_in_ms: 50})
    :ets.delete_all_objects(Tracker.table_name())
    tenant = random_string()
    %{tenant: tenant}
  end

  describe "track/2" do
    test "is able to track channels per transport pid", %{tenant: tenant} do
      pid = self()
      Tracker.track(pid, tenant)

      assert Tracker.count(pid, tenant) == 1
    end

    test "is able to track multiple channels per transport pid", %{tenant: tenant} do
      pid = self()
      Tracker.track(pid, tenant)
      Tracker.track(pid, tenant)

      assert Tracker.count(pid, tenant) == 2
    end
  end

  describe "untrack/2" do
    test "is able to untrack a transport pid", %{tenant: tenant} do
      pid = self()

      Tracker.track(pid, tenant)
      Tracker.untrack(pid, tenant)

      assert Tracker.count(pid, tenant) == 0
    end
  end

  describe "count/2" do
    test "is able to count the number of channels per transport pid", %{tenant: tenant} do
      pid = self()
      Tracker.track(pid, tenant)
      Tracker.track(pid, tenant)

      assert Tracker.count(pid, tenant) == 2
      assert Tracker.count(pid, "other_tenant_external_id") == 0
    end
  end

  describe "list_pids/1" do
    test "is able to list all pids in the table and their count", %{tenant: tenant} do
      pid = self()
      Tracker.track(pid, tenant)
      Tracker.track(pid, tenant)

      assert Tracker.list_pids() == [{{pid, tenant}, 2}]
    end
  end

  def handle_telemetry(event, metadata, content, pid: pid), do: send(pid, {event, metadata, content})

  describe "egress telemetry" do
    setup do
      event = [:realtime, :connections, :output_bytes]
      test_pid = self()
      :telemetry.attach(__MODULE__, event, &__MODULE__.handle_telemetry/4, pid: test_pid)

      on_exit(fn -> :telemetry.detach(__MODULE__) end)

      %{event: event}
    end

    test "emits telemetry with output bytes for transport pids with TCP sockets", %{event: event, tenant: tenant} do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_, port}} = :inet.sockname(listen_socket)
      spawn_send_random_bytes(port, tenant)

      assert_receive {^event, %{output_bytes: output_bytes}, %{tenant_external_id: ^tenant}}, 200
      assert output_bytes == 5000

      :ok = :gen_tcp.close(listen_socket)
    end

    test "does not emit telemetry for transport pids with no TCP sockets", %{event: event, tenant: tenant} do
      pid = spawn(fn -> :timer.sleep(:infinity) end)
      Tracker.track(pid, tenant)
      refute_receive {^event, _, %{tenant_external_id: ^tenant}}, 1000
    end

    test "does not emit telemetry for transport pids with no output bytes", %{event: event, tenant: tenant} do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_, port}} = :inet.sockname(listen_socket)
      spawn_send_random_bytes(port, tenant, 0)
      refute_receive {^event, _, %{tenant_external_id: ^tenant}}, 1000
    end

    test "emits telemetry for multiple tenants and accumulates output bytes", %{event: event} do
      tenant_1 = random_string()
      tenant_2 = random_string()
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, {_, port}} = :inet.sockname(listen_socket)

      spawn_send_random_bytes(port, tenant_1)
      spawn_send_random_bytes(port, tenant_2)

      assert_receive {^event, %{output_bytes: output_bytes_1}, %{tenant_external_id: ^tenant_1}}, 500
      assert_receive {^event, %{output_bytes: output_bytes_2}, %{tenant_external_id: ^tenant_2}}, 500

      assert output_bytes_1 == 5000
      assert output_bytes_2 == 5000

      spawn_send_random_bytes(port, tenant_1)
      spawn_send_random_bytes(port, tenant_2)

      assert_receive {^event, %{output_bytes: output_bytes_1}, %{tenant_external_id: ^tenant_1}}, 500
      assert_receive {^event, %{output_bytes: output_bytes_2}, %{tenant_external_id: ^tenant_2}}, 500

      assert output_bytes_1 == 10_000
      assert output_bytes_2 == 10_000

      :ok = :gen_tcp.close(listen_socket)
    end
  end

  test "kills tracked pid when no channels are open", %{tenant: tenant} do
    assert Tracker.table_name() |> :ets.tab2list() |> length() == 0

    pids =
      for _ <- 1..10_500 do
        pid = spawn(fn -> :timer.sleep(:infinity) end)

        Tracker.track(pid, tenant)
        Tracker.untrack(pid, tenant)

        Enum.random([true, false]) && Tracker.untrack(pid, tenant)
        pid
      end

    Process.sleep(150)

    for pid <- pids, do: refute(Process.alive?(pid))
    assert Tracker.table_name() |> :ets.tab2list() |> length() == 0
  end

  defp spawn_send_random_bytes(port, tenant, payload_size \\ 250) do
    spawn(fn ->
      {:ok, socket} = :gen_tcp.connect(:localhost, port, [:binary, active: false])
      Tracker.track(self(), tenant)
      for _ <- 1..20, do: :gen_tcp.send(socket, :crypto.strong_rand_bytes(payload_size))
      :timer.sleep(:infinity)
    end)
  end
end
