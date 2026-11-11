defmodule Realtime.PresenceTest do
  # The mode comes from two feature flags. The stub is global because the Rollcall tracker reads the
  # flags too, when it publishes a diff. The tests cannot run at the same time as other tests.
  use ExUnit.Case, async: false
  use Mimic

  import ExUnit.CaptureLog

  setup :set_mimic_global

  alias Phoenix.Socket.Broadcast
  alias Realtime.Presence
  alias Realtime.Presence.PhoenixBackend
  alias Realtime.Presence.RollcallBackend
  alias RealtimeWeb.RealtimeChannel.MessageDispatcher
  alias RealtimeWeb.Socket.V2Serializer

  @shadow "presence_rollcall_shadow"
  @primary "presence_rollcall_primary"
  @diff_timeout 2_000

  setup do
    id = System.unique_integer([:positive])
    {:ok, tenant: "tenant-#{id}", topic: "realtime:presence-facade-#{id}", client: client()}
  end

  # A node that has listeners and tracks nothing needs a Rollcall tracker, so that it holds the
  # entries of its peers. The Phoenix mode does not use Rollcall.
  describe "watch/1" do
    test "starts no Rollcall tracker with no flag set", %{tenant: tenant} do
      enable([])

      assert :ok = Presence.watch(tenant)

      refute tenant in Realtime.Presence.Rollcall.scopes()
    end

    test "starts the Rollcall tracker of the tenant in shadow mode", %{tenant: tenant} do
      enable([@shadow])

      assert :ok = Presence.watch(tenant)

      assert tenant in Realtime.Presence.Rollcall.scopes()
    end

    test "starts the Rollcall tracker of the tenant in Rollcall mode", %{tenant: tenant} do
      enable([@primary])

      assert :ok = Presence.watch(tenant)

      assert tenant in Realtime.Presence.Rollcall.scopes()
    end

    # The shadow mode must not change what the client gets. The channel calls watch/1 when it syncs.
    test "returns :ok in shadow mode when the tracker does not start, and emits an event", %{tenant: tenant} do
      enable([@shadow])
      attach_shadow_error()
      stub(Realtime.Presence.Rollcall, :ensure_started, fn _tenant -> {:error, :boom} end)

      assert :ok = Presence.watch(tenant)

      assert_receive {:shadow_error, %{operation: :watch, tenant: ^tenant}}
    end

    test "returns :ok in shadow mode when Rollcall raises, and emits an event", %{tenant: tenant} do
      enable([@shadow])
      attach_shadow_error()
      stub(Realtime.Presence.Rollcall, :ensure_started, fn _tenant -> raise "boom" end)

      assert :ok = Presence.watch(tenant)

      assert_receive {:shadow_error, %{operation: :watch, tenant: ^tenant}}
    end

    test "returns :ok in shadow mode when Rollcall exits, and emits an event", %{tenant: tenant} do
      enable([@shadow])
      attach_shadow_error()
      stub(Realtime.Presence.Rollcall, :ensure_started, fn _tenant -> exit(:timeout) end)

      assert :ok = Presence.watch(tenant)

      assert_receive {:shadow_error, %{operation: :watch, tenant: ^tenant}}
    end

    # In Rollcall mode a failed start leaves the node with no state. The log is the only signal.
    test "returns the error and logs it in Rollcall mode when the tracker does not start", %{tenant: tenant} do
      enable([@primary])
      stub(Realtime.Presence.Rollcall, :ensure_started, fn _tenant -> {:error, :boom} end)

      log = capture_log(fn -> assert {:error, :boom} = Presence.watch(tenant) end)

      assert log =~ "boom"
    end
  end

  describe "with no flag set" do
    test "tracks in Phoenix only", %{tenant: tenant, topic: topic, client: client} do
      enable([])

      {:ok, :track, ref} = Presence.track(client, tenant, topic, "alice", %{"status" => "online"})

      assert PhoenixBackend.list(topic) == %{"alice" => %{metas: [%{"status" => "online", phx_ref: ref}]}}
      assert RollcallBackend.list(tenant, topic) == %{}
    end
  end

  describe "in shadow mode" do
    setup do
      enable([@shadow])
    end

    test "tracks and updates in both backends with the same refs", %{tenant: tenant, topic: topic, client: client} do
      {:ok, :track, first} = Presence.track(client, tenant, topic, "alice", %{"status" => "online"})
      assert RollcallBackend.list(tenant, topic) == PhoenixBackend.list(topic)

      {:ok, :update, second} = Presence.track(client, tenant, topic, "alice", %{"status" => "away"})

      assert PhoenixBackend.list(topic) == %{
               "alice" => %{metas: [%{"status" => "away", phx_ref: second, phx_ref_prev: first}]}
             }

      assert RollcallBackend.list(tenant, topic) == PhoenixBackend.list(topic)
    end

    test "untracks in both backends", %{tenant: tenant, topic: topic, client: client} do
      {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})

      assert :ok = Presence.untrack(client, tenant, topic, "alice")

      assert PhoenixBackend.list(topic) == %{}
      assert RollcallBackend.list(tenant, topic) == %{}
    end

    test "reads from Phoenix", %{tenant: tenant, topic: topic, client: client} do
      {:ok, :track, ref} = Presence.track(client, tenant, topic, "alice", %{})
      {:ok, :track, _ref} = RollcallBackend.track(client(), tenant, topic, "only-in-rollcall", %{})

      assert Presence.list(tenant, topic) == %{"alice" => %{metas: [%{phx_ref: ref}]}}
    end

    test "does not track in Rollcall when Phoenix returns an error", %{tenant: tenant, topic: topic, client: client} do
      stub(PhoenixBackend, :track, fn _pid, _topic, _key, _meta -> {:error, :track, :boom} end)

      assert {:error, :track, :boom} = Presence.track(client, tenant, topic, "alice", %{})

      assert RollcallBackend.list(tenant, topic) == %{}
    end

    test "returns the Phoenix result when Rollcall raises, and emits an event", %{
      tenant: tenant,
      topic: topic,
      client: client
    } do
      attach_shadow_error()
      stub(RollcallBackend, :track, fn _pid, _tenant, _topic, _key, _meta, _opts -> raise "boom" end)

      assert {:ok, :track, ref} = Presence.track(client, tenant, topic, "alice", %{})

      assert PhoenixBackend.list(topic) == %{"alice" => %{metas: [%{phx_ref: ref}]}}
      assert_receive {:shadow_error, %{operation: :track, tenant: ^tenant, reason: :error}}
    end

    test "returns the Phoenix result when Rollcall exits, and emits an event", %{
      tenant: tenant,
      topic: topic,
      client: client
    } do
      attach_shadow_error()
      stub(RollcallBackend, :track, fn _pid, _tenant, _topic, _key, _meta, _opts -> exit(:timeout) end)

      assert {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})

      assert_receive {:shadow_error, %{operation: :track, tenant: ^tenant}}
    end

    test "returns :ok when Rollcall fails to untrack, and emits an event", %{
      tenant: tenant,
      topic: topic,
      client: client
    } do
      attach_shadow_error()
      {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})
      stub(RollcallBackend, :untrack, fn _pid, _tenant, _topic, _key, _opts -> raise "boom" end)

      assert :ok = Presence.untrack(client, tenant, topic, "alice")

      assert PhoenixBackend.list(topic) == %{}
      assert_receive {:shadow_error, %{operation: :untrack, tenant: ^tenant}}
    end

    # A suspended tracker handles no message. The default call timeout is 5000 ms, so a bound of
    # one second shows that the facade passes a short timeout. The call still reaches the tracker
    # after it resumes.
    test "returns the Phoenix result at the timeout when the Rollcall tracker is stuck, and emits a timeout event", %{
      tenant: tenant,
      topic: topic,
      client: client
    } do
      attach_shadow_error()
      tracker = suspend_tracker(tenant)

      {elapsed, result} = :timer.tc(fn -> Presence.track(client, tenant, topic, "alice", %{}) end)

      assert {:ok, :track, _ref} = result
      assert elapsed < 1_000_000
      assert_receive {:shadow_error, %{operation: :track, tenant: ^tenant, reason: :timeout}}

      resume_tracker(tracker)

      assert RollcallBackend.list(tenant, topic) == PhoenixBackend.list(topic)
    end

    test "returns :ok at the timeout when the Rollcall tracker is stuck on an untrack, and emits a timeout event", %{
      tenant: tenant,
      topic: topic,
      client: client
    } do
      attach_shadow_error()
      {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})
      tracker = suspend_tracker(tenant)

      {elapsed, result} = :timer.tc(fn -> Presence.untrack(client, tenant, topic, "alice") end)

      assert result == :ok
      assert elapsed < 1_000_000
      assert_receive {:shadow_error, %{operation: :untrack, tenant: ^tenant, reason: :timeout}}

      resume_tracker(tracker)

      assert RollcallBackend.list(tenant, topic) == %{}
    end

    test "leaves no entry in Rollcall for a track and an untrack that time out", %{
      tenant: tenant,
      topic: topic,
      client: client
    } do
      tracker = suspend_tracker(tenant)

      {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})
      :ok = Presence.untrack(client, tenant, topic, "alice")
      resume_tracker(tracker)

      assert PhoenixBackend.list(topic) == %{}
      assert RollcallBackend.list(tenant, topic) == %{}
    end

    test "sends one presence_diff for a track", %{tenant: tenant, topic: topic, client: client} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, topic)

      {:ok, :track, ref} = Presence.track(client, tenant, topic, "alice", %{})

      assert_receive %Broadcast{event: "presence_diff", payload: %{joins: %{"alice" => %{metas: [%{phx_ref: ^ref}]}}}},
                     @diff_timeout

      refute_receive %Broadcast{event: "presence_diff"}, 500
    end
  end

  describe "in Rollcall mode" do
    setup do
      enable([@primary])
    end

    test "tracks, updates and untracks in Rollcall only", %{tenant: tenant, topic: topic, client: client} do
      {:ok, :track, first} = Presence.track(client, tenant, topic, "alice", %{"status" => "online"})
      {:ok, _action, second} = Presence.track(client, tenant, topic, "alice", %{"status" => "away"})

      assert RollcallBackend.list(tenant, topic) == %{
               "alice" => %{metas: [%{"status" => "away", phx_ref: second, phx_ref_prev: first}]}
             }

      assert PhoenixBackend.list(topic) == %{}

      assert :ok = Presence.untrack(client, tenant, topic, "alice")

      assert RollcallBackend.list(tenant, topic) == %{}
    end

    test "reads from Rollcall", %{tenant: tenant, topic: topic, client: client} do
      {:ok, :track, ref} = Presence.track(client, tenant, topic, "alice", %{"status" => "online"})
      {:ok, :track, _ref} = PhoenixBackend.track(client(), topic, "only-in-phoenix", %{})

      assert Presence.list(tenant, topic) == %{"alice" => %{metas: [%{"status" => "online", phx_ref: ref}]}}
    end

    test "sends one presence_diff for a track", %{tenant: tenant, topic: topic, client: client} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, topic)

      {:ok, :track, ref} = Presence.track(client, tenant, topic, "alice", %{})

      assert_receive %Broadcast{event: "presence_diff", payload: %{joins: %{"alice" => %{metas: [%{phx_ref: ^ref}]}}}},
                     @diff_timeout

      refute_receive %Broadcast{event: "presence_diff"}, 500
      # Phoenix tracked nothing, so Rollcall sent the diff.
      assert PhoenixBackend.list(topic) == %{}
    end

    test "waits for a stuck Rollcall tracker with the default timeout", %{
      tenant: tenant,
      topic: topic,
      client: client
    } do
      tracker = suspend_tracker(tenant)
      task = Task.async(fn -> Presence.track(client, tenant, topic, "alice", %{}) end)

      # The shadow timeout is 100 ms. A call with that timeout has exited by now.
      assert Task.yield(task, 500) == nil

      resume_tracker(tracker)

      assert {:ok, :track, _ref} = Task.await(task)
    end

    test "wins over the shadow flag", %{tenant: tenant, topic: topic, client: client} do
      enable([@shadow, @primary])

      {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})

      assert PhoenixBackend.list(topic) == %{}
      assert map_size(RollcallBackend.list(tenant, topic)) == 1
    end
  end

  describe "the metric of a track" do
    setup do
      id = {__MODULE__, make_ref()}
      :telemetry.attach(id, [:realtime, :presence, :track, :duration], &__MODULE__.handle_duration/4, self())
      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "has the implementation :phoenix with no flag set", %{tenant: tenant, topic: topic, client: client} do
      enable([])

      {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})

      assert_receive {:duration, %{implementation: :phoenix, action: :track, result: :ok}, _ms}
    end

    test "has one observation for each implementation, timed separately, in shadow mode", %{
      tenant: tenant,
      topic: topic,
      client: client
    } do
      enable([@shadow])

      stub(RollcallBackend, :track, fn _pid, _tenant, _topic, _key, _meta, opts ->
        Process.sleep(200)
        {:ok, :track, Keyword.fetch!(opts, :ref)}
      end)

      {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})

      assert_receive {:duration, %{implementation: :phoenix, action: :track, result: :ok}, phoenix_ms}, 1_000
      assert_receive {:duration, %{implementation: :rollcall, action: :track, result: :ok}, rollcall_ms}, 1_000
      assert phoenix_ms < 200
      assert rollcall_ms >= 200
    end

    test "has the implementation :rollcall in Rollcall mode", %{tenant: tenant, topic: topic, client: client} do
      enable([@primary])

      {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})

      assert_receive {:duration, %{implementation: :rollcall, action: :track, result: :ok}, _ms}
    end
  end

  describe "the notify latency metric of a sampled presence_diff" do
    @notify_latency [:realtime, :presence, :notify, :latency]

    setup %{tenant: tenant} do
      sample_rate = Application.get_env(:realtime, :presence_latency_sample_rate)
      Application.put_env(:realtime, :presence_latency_sample_rate, 1.0)
      on_exit(fn -> Application.put_env(:realtime, :presence_latency_sample_rate, sample_rate) end)

      id = {__MODULE__, make_ref()}
      :telemetry.attach(id, @notify_latency, &__MODULE__.handle_notify_latency/4, %{pid: self(), tenant: tenant})
      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "has the implementation :phoenix with no flag set", ctx do
      track_with_fastlane_subscriber(ctx, ["presence_latency_metric"])

      assert_receive {:notify_latency, %{implementation: :phoenix, path: :fastlane}}
      refute_receive {:notify_latency, _}, 500
    end

    test "has one observation for each implementation in shadow mode", ctx do
      track_with_fastlane_subscriber(ctx, ["presence_latency_metric", @shadow])

      assert_receive {:notify_latency, %{implementation: :phoenix, path: :fastlane}}
      assert_receive {:notify_latency, %{implementation: :rollcall, path: :transport}}
      refute_receive {:notify_latency, _}, 500
    end

    test "has no observation for the leave of an untrack in shadow mode",
         %{
           tenant: tenant,
           topic: topic,
           client: client
         } = ctx do
      track_with_fastlane_subscriber(ctx, ["presence_latency_metric", @shadow])
      assert_receive {:notify_latency, %{implementation: :phoenix}}
      assert_receive {:notify_latency, %{implementation: :rollcall}}

      :ok = Presence.untrack(client, tenant, topic, "alice")

      assert_presence_diff_pushed()
      refute_receive {:notify_latency, _}, 500
    end

    test "has one observation for each implementation for an update in shadow mode",
         %{
           tenant: tenant,
           topic: topic,
           client: client
         } = ctx do
      track_with_fastlane_subscriber(ctx, ["presence_latency_metric", @shadow])
      assert_receive {:notify_latency, %{implementation: :phoenix}}
      assert_receive {:notify_latency, %{implementation: :rollcall}}

      {:ok, :update, _ref} = Presence.track(client, tenant, topic, "alice", %{"status" => "away"})

      assert_presence_diff_pushed()
      assert_receive {:notify_latency, %{implementation: :phoenix, action: :update}}
      assert_receive {:notify_latency, %{implementation: :rollcall, action: :update}}
      refute_receive {:notify_latency, _}, 500
    end

    test "has the implementation :rollcall in Rollcall mode", ctx do
      track_with_fastlane_subscriber(ctx, ["presence_latency_metric", @primary])

      assert_receive {:notify_latency, %{implementation: :rollcall, path: :fastlane}}
      refute_receive {:notify_latency, _}, 500
    end
  end

  def handle_notify_latency(_event, _measurements, %{tenant: tenant} = metadata, %{pid: pid, tenant: tenant}),
    do: send(pid, {:notify_latency, metadata})

  def handle_notify_latency(_event, _measurements, _metadata, _config), do: :ok

  def handle_duration(_event, %{duration: duration}, metadata, pid) do
    send(pid, {:duration, metadata, duration})
  end

  def handle_shadow_error(_event, _measurements, metadata, pid), do: send(pid, {:shadow_error, metadata})

  # Subscribes the test process as a channel does, tracks one entry and waits for its presence_diff.
  # The dispatcher records the notify latency only for a fastlane subscriber.
  defp track_with_fastlane_subscriber(%{tenant: tenant, topic: topic, client: client}, flags) do
    enable(flags)
    metadata = MessageDispatcher.fastlane_metadata(self(), V2Serializer, topic, :error, tenant)
    :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, topic, metadata: metadata)

    {:ok, :track, _ref} = Presence.track(client, tenant, topic, "alice", %{})

    assert_presence_diff_pushed()
  end

  defp assert_presence_diff_pushed do
    assert_receive {:socket_push, :text, payload}, @diff_timeout
    assert payload =~ "presence_diff"
  end

  # Sets the flags that are on. Any other flag is off.
  defp enable(flags) do
    stub(Realtime.FeatureFlags, :enabled?, fn flag, _tenant -> flag in flags end)
    :ok
  end

  defp attach_shadow_error do
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:realtime, :presence, :shadow, :error], &__MODULE__.handle_shadow_error/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  # A process that stays alive until the test ends. Presence removes its entries after that.
  defp client, do: spawn_link(fn -> Process.sleep(:infinity) end)

  # Starts the Rollcall tracker of the tenant and suspends it. A suspended tracker handles no
  # message, so a call to it waits until its timeout. The test resumes the tracker with
  # `resume_tracker/1`. The `on_exit` callback resumes it when the test fails first.
  defp suspend_tracker(tenant) do
    :ok = Realtime.Presence.Rollcall.ensure_started(tenant)
    tracker = Rollcall.Tracker.whereis(Realtime.Presence.Rollcall, tenant)
    :ok = :sys.suspend(tracker)
    on_exit(fn -> if Process.alive?(tracker), do: :sys.resume(tracker) end)
    tracker
  end

  # Resumes the tracker and waits until it handles the calls that it received.
  defp resume_tracker(tracker) do
    :ok = :sys.resume(tracker)
    _ = :sys.get_state(tracker)
    :ok
  end
end
