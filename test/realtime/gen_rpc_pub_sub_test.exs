Application.put_env(:phoenix_pubsub, :test_adapter, {Realtime.GenRpcPubSub, []})
Code.require_file("../../deps/phoenix_pubsub/test/shared/pubsub_test.exs", __DIR__)

defmodule Realtime.GenRpcPubSubTest do
  # Application env being changed
  use ExUnit.Case, async: false

  alias Forum.Muster
  alias Realtime.FeatureFlags
  alias Realtime.GenRpcPubSub.Worker
  alias RealtimeWeb.RealtimeChannel.MessageDispatcher

  test "it sets off_heap message_queue_data flag on the workers" do
    assert Realtime.PubSubElixir.Realtime.PubSub.Adapter_1
           |> Process.whereis()
           |> Process.info(:message_queue_data) == {:message_queue_data, :off_heap}
  end

  test "it sets fullsweep_after flag on the workers" do
    assert Realtime.PubSubElixir.Realtime.PubSub.Adapter_1
           |> Process.whereis()
           |> Process.info(:fullsweep_after) == {:fullsweep_after, 20}
  end

  @aux_mod (quote do
              defmodule Subscriber do
                # Relay messages to testing node
                def subscribe(subscriber, topic) do
                  spawn(fn ->
                    RealtimeWeb.Endpoint.subscribe(topic)
                    2 = length(Realtime.Nodes.region_nodes("us-east-1"))
                    2 = length(Realtime.Nodes.region_nodes("ap-southeast-2"))
                    send(subscriber, {:ready, Application.get_env(:realtime, :region)})

                    loop = fn f ->
                      receive do
                        msg -> send(subscriber, {:relay, node(), msg})
                      end

                      f.(f)
                    end

                    loop.(loop)
                  end)
                end

                # Register a long-lived local member for the tenant so this node reports hit=true.
                def add_user(tenant_id) do
                  pid = spawn(fn -> Process.sleep(:infinity) end)
                  :ok = Realtime.UsersCounter.add(pid, tenant_id)
                end

                # Relay the fan-out telemetry emitted on this (receiving) node back to the test process.
                def attach_fanout(dest) do
                  :telemetry.attach(
                    {__MODULE__, dest},
                    [:realtime, :broadcast, :fanout, :node_delivery],
                    &__MODULE__.relay_fanout/4,
                    dest
                  )
                end

                def relay_fanout(_event, measurements, metadata, dest) do
                  send(dest, {:fanout, node(), measurements, metadata})
                end

                # Region-agnostic relay (unlike subscribe/2, no fixed topology asserts).
                def subscribe_relay(subscriber, topic) do
                  spawn(fn ->
                    RealtimeWeb.Endpoint.subscribe(topic)
                    send(subscriber, {:subscribed, node()})

                    loop = fn f ->
                      receive do
                        msg -> send(subscriber, {:relay, node(), msg})
                      end

                      f.(f)
                    end

                    loop.(loop)
                  end)
                end

                # Register a long-lived local Muster member for the tenant so this node
                # shows up in the router's occupancy set for `group`.
                def muster_join(scope, group) do
                  pid = spawn(fn -> Process.sleep(:infinity) end)
                  :ok = Forum.Muster.join(scope, group, pid)
                  pid
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  @topic "gen-rpc-pub-sub-test-topic"

  describe "regional broadcasting" do
    setup do
      previous_region = Application.get_env(:realtime, :region)
      Application.put_env(:realtime, :region, "us-east-1")
      on_exit(fn -> Application.put_env(:realtime, :region, previous_region) end)

      :ok
    end

    test "broadcasts fan out across regions and each receiving node emits fan-out telemetry" do
      # start 1 node in us-east-1 to test my region broadcasting
      # start 2 nodes in ap-southeast-2 to test other region broadcasting

      us_node = :us_node
      ap2_nodeX = :ap2_nodeX
      ap2_nodeY = :ap2_nodeY

      # Avoid port collision
      gen_rpc_port = Application.fetch_env!(:gen_rpc, :tcp_server_port)

      client_config_per_node = %{
        node() => gen_rpc_port,
        :"#{us_node}@127.0.0.1" => 16970,
        :"#{ap2_nodeX}@127.0.0.1" => 16971,
        :"#{ap2_nodeY}@127.0.0.1" => 16972
      }

      extra_config = [{:gen_rpc, :client_config_per_node, {:internal, client_config_per_node}}]

      on_exit(fn -> Application.put_env(:gen_rpc, :client_config_per_node, {:internal, %{}}) end)
      Application.put_env(:gen_rpc, :client_config_per_node, {:internal, client_config_per_node})

      us_extra_config =
        [{:realtime, :region, "us-east-1"}, {:gen_rpc, :tcp_server_port, 16970}] ++ extra_config

      {:ok, _} = Clustered.start(@aux_mod, name: us_node, extra_config: us_extra_config, phoenix_port: 4014)

      ap2_nodeX_extra_config =
        [{:realtime, :region, "ap-southeast-2"}, {:gen_rpc, :tcp_server_port, 16971}] ++ extra_config

      {:ok, _} = Clustered.start(@aux_mod, name: ap2_nodeX, extra_config: ap2_nodeX_extra_config, phoenix_port: 4015)

      ap2_nodeY_extra_config =
        [{:realtime, :region, "ap-southeast-2"}, {:gen_rpc, :tcp_server_port, 16972}] ++ extra_config

      {:ok, _} = Clustered.start(@aux_mod, name: ap2_nodeY, extra_config: ap2_nodeY_extra_config, phoenix_port: 4016)

      # Ensuring that syn had enough time to propagate to all nodes the group information
      Process.sleep(3000)

      RealtimeWeb.Endpoint.subscribe(@topic)
      :erpc.multicall(Node.list(), Subscriber, :subscribe, [self(), @topic])

      assert length(Realtime.Nodes.region_nodes("us-east-1")) == 2
      assert length(Realtime.Nodes.region_nodes("ap-southeast-2")) == 2

      assert_receive {:ready, "us-east-1"}
      assert_receive {:ready, "ap-southeast-2"}
      assert_receive {:ready, "ap-southeast-2"}

      # Relay the fan-out telemetry emitted on every receiving node back to this process.
      for node <- Node.list(), do: :ok = :erpc.call(node, Subscriber, :attach_fanout, [self()])

      # Untagged broadcast: delivered to every node, but a no-op for fan-out telemetry.
      message = %Phoenix.Socket.Broadcast{topic: @topic, event: "an event", payload: ["a", %{"b" => "c"}, 1, 23]}
      Phoenix.PubSub.broadcast(Realtime.PubSub, @topic, message)

      assert_receive ^message

      # Remote nodes received the broadcast
      assert_receive {:relay, :"us_node@127.0.0.1", ^message}, 5000
      assert_receive {:relay, :"ap2_nodeX@127.0.0.1", ^message}, 1000
      assert_receive {:relay, :"ap2_nodeY@127.0.0.1", ^message}, 1000

      # Untagged messages do not emit fan-out telemetry
      refute_receive {:fanout, _, _, _}
      refute_receive _any

      # Tagged broadcast: fans out via :ftl (us_node, same region) and :ftr (ap nodes, other region),
      # and each receiving node emits the fan-out telemetry. Register a connection on us_node so it
      # reports hit=true while the ap nodes report hit=false.
      tenant_id = "fanout-#{System.unique_integer([:positive])}"
      :ok = :erpc.call(:"us_node@127.0.0.1", Subscriber, :add_user, [tenant_id])

      tagged_message = %Phoenix.Socket.Broadcast{topic: @topic, event: "an event", payload: %{"a" => "b"}}

      Phoenix.PubSub.broadcast(
        Realtime.PubSub,
        @topic,
        {:tb, tenant_id, tagged_message},
        RealtimeWeb.RealtimeChannel.MessageDispatcher
      )

      # The tag is stripped before delivery: subscribers only ever see the underlying struct
      assert_receive ^tagged_message
      assert_receive {:relay, :"us_node@127.0.0.1", ^tagged_message}, 5000
      assert_receive {:relay, :"ap2_nodeX@127.0.0.1", ^tagged_message}, 1000
      assert_receive {:relay, :"ap2_nodeY@127.0.0.1", ^tagged_message}, 1000

      # us_node holds a connection for the tenant (:ftl path) -> hit=true
      assert_receive {:fanout, :"us_node@127.0.0.1", %{local_tenant_users: us_count}, %{tenant: ^tenant_id, hit: true}},
                     5000

      assert us_count >= 1

      # ap nodes hold no connection for the tenant (:ftr path + its re-forwarded :ftl) -> hit=false
      assert_receive {:fanout, :"ap2_nodeX@127.0.0.1", %{local_tenant_users: 0}, %{tenant: ^tenant_id, hit: false}},
                     1000

      assert_receive {:fanout, :"ap2_nodeY@127.0.0.1", %{local_tenant_users: 0}, %{tenant: ^tenant_id, hit: false}},
                     1000

      refute_receive _any
    end
  end

  describe "muster-routed broadcasting (use_muster_broadcast)" do
    setup do
      previous_region = Application.get_env(:realtime, :region)
      Application.put_env(:realtime, :region, "us-east-1")
      on_exit(fn -> Application.put_env(:realtime, :region, previous_region) end)

      :ok
    end

    test "delivers to origin subscribers exactly once (routed path excludes the origin)" do
      scope = Application.fetch_env!(:realtime, :muster_scope)
      wait_until(fn -> Muster.status(scope) == :ready end)

      tenant_id = "muster-bcast-#{System.unique_integer([:positive])}"
      topic = "muster-bcast-#{System.unique_integer([:positive])}"

      # The origin holds the tenant, so Muster names this node the router and lists
      # it in the occupancy set.
      member = spawn_link(fn -> Process.sleep(:infinity) end)
      :ok = Muster.join(scope, tenant_id, member)
      assert Muster.targets(scope, tenant_id, Muster.view_hash(scope)) == {:ok, [node()]}

      enable_broadcast_flag!(tenant_id)
      RealtimeWeb.Endpoint.subscribe(topic)

      message = %Phoenix.Socket.Broadcast{topic: topic, event: "an event", payload: %{"a" => "b"}}
      Phoenix.PubSub.broadcast(Realtime.PubSub, topic, {:tb, tenant_id, message}, MessageDispatcher)

      # Phoenix's local dispatch delivers the (tag-stripped) struct on the origin...
      assert_receive ^message
      # ...and the routed path must NOT fan a second copy back to the origin.
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic}, 200
    end

    test "prunes intra-region fanout to the tenant's holders for every router placement" do
      %{holder_node: holder_node, bystander_node: bystander_node, scope: scope} = start_us_east_region_cluster()

      # Exercise all three router placements deterministically by picking a group key
      # whose hash-ring router lands on the intended node: the broadcasting node
      # itself, the node that holds the tenant, and a third node that holds nothing.
      # These are distinct code paths (local send vs remote route-hop; local_broadcast
      # vs :ftl; router-is-a-holder vs router-holds-nothing).
      placements = [{"origin", node()}, {"holder", holder_node}, {"bystander", bystander_node}]

      for {label, router_node} <- placements do
        tenant_id = group_routed_to(scope, router_node)
        assert Muster.router(scope, tenant_id) == {:ok, router_node}

        # Only the holder joins the tenant's Muster group.
        _pid = :erpc.call(holder_node, Subscriber, :muster_join, [scope, tenant_id])

        enable_broadcast_flag!(tenant_id)

        topic = "muster-prune-#{label}-#{System.unique_integer([:positive])}"
        RealtimeWeb.Endpoint.subscribe(topic)
        subscribe_region_relays(holder_node, bystander_node, topic)

        message = %Phoenix.Socket.Broadcast{topic: topic, event: "e", payload: %{"router" => label}}
        Phoenix.PubSub.broadcast(Realtime.PubSub, topic, {:tb, tenant_id, message}, MessageDispatcher)

        # Origin always delivers locally; the holder is routed to; the bystander is pruned.
        assert_receive ^message, 1000, "origin should receive locally (router=#{label})"
        assert_receive {:relay, ^holder_node, ^message}, 5000, "holder should receive (router=#{label})"
        refute_receive {:relay, ^bystander_node, _}, 500
      end
    end

    test "over-delivers to the whole region when the router cannot trust its routing" do
      %{holder_node: holder_node, bystander_node: bystander_node, scope: scope} = start_us_east_region_cluster()

      # A group whose router is the holder, held only by the holder.
      tenant_id = group_routed_to(scope, holder_node)
      _pid = :erpc.call(holder_node, Subscriber, :muster_join, [scope, tenant_id])

      # Case 1: the sender saw a different cluster view. We hand the router a route
      # tagged with a stale view_hash, so `targets/3` cannot decide and the router
      # must flood the whole region (the bystander too), even though only the holder
      # actually holds the tenant.
      topic1 = "muster-flood-staleview-#{System.unique_integer([:positive])}"
      subscribe_region_relays(holder_node, bystander_node, topic1)
      message1 = %Phoenix.Socket.Broadcast{topic: topic1, event: "e", payload: %{"case" => "stale-view"}}
      stale_view_hash = Muster.view_hash(scope) + 1

      # The routed message carries the tenant tag, exactly as the adapter forwards it.
      route_to_worker(
        holder_node,
        Worker.route(scope, tenant_id, topic1, {:tb, tenant_id, message1}, MessageDispatcher, node(), stale_view_hash)
      )

      assert_receive {:relay, ^holder_node, ^message1}, 5000
      assert_receive {:relay, ^bystander_node, ^message1}, 5000

      # Case 2: the router changed under us. We send the route to the bystander, which
      # is NOT the router for this tenant (the origin thought it was, but the ring
      # moved). It must recognise this and just fan out to the region rather than
      # trust a stale decision
      topic2 = "muster-flood-wrongrouter-#{System.unique_integer([:positive])}"
      subscribe_region_relays(holder_node, bystander_node, topic2)
      message2 = %Phoenix.Socket.Broadcast{topic: topic2, event: "e", payload: %{"case" => "wrong-router"}}
      view_hash = Muster.view_hash(scope)

      route_to_worker(
        bystander_node,
        Worker.route(scope, tenant_id, topic2, {:tb, tenant_id, message2}, MessageDispatcher, node(), view_hash)
      )

      assert_receive {:relay, ^holder_node, ^message2}, 5000
      assert_receive {:relay, ^bystander_node, ^message2}, 5000
    end
  end

  # Start two extra us-east-1 nodes (holder + bystander) so the origin makes three,
  # and wait until the region's Muster ring is :ready and agrees on a single view.
  defp start_us_east_region_cluster do
    gen_rpc_port = Application.fetch_env!(:gen_rpc, :tcp_server_port)

    holder = :holder_node
    bystander = :bystander_node

    client_config_per_node = %{
      node() => gen_rpc_port,
      :"#{holder}@127.0.0.1" => 16980,
      :"#{bystander}@127.0.0.1" => 16981
    }

    on_exit(fn -> Application.put_env(:gen_rpc, :client_config_per_node, {:internal, %{}}) end)
    Application.put_env(:gen_rpc, :client_config_per_node, {:internal, client_config_per_node})
    extra_config = [{:gen_rpc, :client_config_per_node, {:internal, client_config_per_node}}]

    holder_config = [{:realtime, :region, "us-east-1"}, {:gen_rpc, :tcp_server_port, 16980}] ++ extra_config
    {:ok, holder_node} = Clustered.start(@aux_mod, name: holder, extra_config: holder_config, phoenix_port: 4024)

    bystander_config = [{:realtime, :region, "us-east-1"}, {:gen_rpc, :tcp_server_port, 16981}] ++ extra_config

    {:ok, bystander_node} =
      Clustered.start(@aux_mod, name: bystander, extra_config: bystander_config, phoenix_port: 4025)

    scope = Application.fetch_env!(:realtime, :muster_scope)
    all_nodes = [node(), holder_node, bystander_node]

    wait_until(
      fn ->
        Enum.all?(all_nodes, fn n -> :erpc.call(n, Muster, :status, [scope]) == :ready end) and
          all_nodes |> Enum.map(&:erpc.call(&1, Muster, :view_hash, [scope])) |> Enum.uniq() |> length() == 1
      end,
      20_000
    )

    %{holder_node: holder_node, bystander_node: bystander_node, scope: scope}
  end

  # Find a group key whose consistent-hash router is `target_node` (all nodes agree
  # on the ring once converged, so it is safe to compute this on the origin).
  defp group_routed_to(scope, target_node) do
    Enum.find_value(1..2000, fn i ->
      id = "muster-route-#{i}-#{System.unique_integer([:positive])}"
      if Muster.router(scope, id) == {:ok, target_node}, do: id
    end) || flunk("no group routed to #{inspect(target_node)}")
  end

  # Inject a routing message straight into a GenRpcPubSub broadcast worker on `target`
  # (bypassing `broadcast/4`) so the router-side flood fallbacks can be exercised
  # deterministically.
  defp route_to_worker(target, route) do
    worker = Realtime.PubSubElixir.Realtime.PubSub.Adapter_1

    send({worker, target}, route)
    :ok
  end

  defp subscribe_region_relays(holder_node, bystander_node, topic) do
    :erpc.call(holder_node, Subscriber, :subscribe_relay, [self(), topic])
    :erpc.call(bystander_node, Subscriber, :subscribe_relay, [self(), topic])
    assert_receive {:subscribed, ^holder_node}, 5000
    assert_receive {:subscribed, ^bystander_node}, 5000
    :ok
  end

  # Poll `fun` until it returns truthy or the timeout elapses.
  defp wait_until(fun, timeout \\ 15_000, interval \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait_until(fun, deadline, interval)
  end

  defp do_wait_until(fun, deadline, interval) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("wait_until timed out")
      true -> Process.sleep(interval) && do_wait_until(fun, deadline, interval)
    end
  end

  # Enable `use_muster_broadcast` for the tenant without touching the DB: seed both
  # the flag cache (so the flag exists) and the tenant cache (with an override), then
  # tear them down so nothing leaks into other async tests via the shared caches.
  defp enable_broadcast_flag!(tenant_id) do
    flag = %Realtime.Api.FeatureFlag{name: "use_muster_broadcast", enabled: true, rollout_percentage: 100}
    {:ok, true} = FeatureFlags.Cache.update_cache(flag)

    tenant = %Realtime.Api.Tenant{external_id: tenant_id, feature_flags: %{"use_muster_broadcast" => true}}
    {:ok, true} = Realtime.Tenants.Cache.update_cache(tenant)

    on_exit(fn ->
      FeatureFlags.Cache.invalidate_cache("use_muster_broadcast")
      Realtime.Tenants.Cache.invalidate_tenant_cache(tenant_id)
    end)
  end
end
