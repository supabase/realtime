defmodule Realtime.SubscriptionManagerTest do
  use ExUnit.Case
  import Mock
  alias Realtime.SubscriptionManager

  @subscription_id "bbb51e4e-f371-4463-bf0a-af8f56dc9a71"
  @claims %{"role" => "authenticated"}

  setup_all do
    start_supervised(Realtime.RLS.Repo)
    :ok
  end

  test "track_topic_subscribers/1" do
    mess = {
      :track_topic_subscribers,
      [
        %{
          channel_pid: self(),
          topic: "test_topic",
          id: @subscription_id,
          claims: @claims
        }
      ]
    }

    assert :ok == SubscriptionManager.track_topic_subscribers(mess)
  end

  test "init/1" do
    rls_opts = [
      subscription_sync_interval: 15_000,
      replication_mode: "RLS"
    ]

    case SubscriptionManager.init(rls_opts) do
      {:ok, res} ->
        assert res.replication_mode == "RLS"
        assert res.sync_interval == 15_000
        assert is_reference(res.sync_ref)

      other ->
        assert match?({:ok, _}, other)
    end
  end

  test "handle_call/track_topic_subscribers, when subscription_params is empty" do
    mess = {
      :track_topic_subscribers,
      [
        %{
          channel_pid: self(),
          params: %{"schema" => "*"},
          id: @subscription_id,
          claims: @claims
        }
      ]
    }

    state = %{replication_mode: "RLS", subscription_params: %{}}

    expected =
      {:reply, :ok,
       %{
         replication_mode: "RLS",
         subscription_params: %{
           self() => [
             %{
               channel_pid: self(),
               params: %{"schema" => "*"},
               id: @subscription_id,
               claims: @claims
             }
           ]
         }
       }}

    assert expected == SubscriptionManager.handle_call(mess, self(), state)
  end

  test "handle_call/track_topic_subscribers, when subscription_params is not empty" do
    mess = {
      :track_topic_subscribers,
      [
        %{
          channel_pid: self(),
          params: %{"schema" => "public", "table" => "*"},
          id: @subscription_id,
          claims: @claims
        }
      ]
    }

    state = %{
      replication_mode: "RLS",
      subscription_params: %{
        self() => [
          %{
            channel_pid: self(),
            params: %{"schema" => "public", "table" => "*"},
            id: @subscription_id,
            claims: @claims
          }
        ]
      },
      sync_interval: 15_000,
      sync_ref: make_ref()
    }

    expected = {:reply, :ok, state}
    assert expected == SubscriptionManager.handle_call(mess, self(), state)
  end

  test "handle_call/track_topic_subscribers, updated state" do
    mess = {
      :track_topic_subscribers,
      [
        %{
          channel_pid: self(),
          params: %{"schema" => "*"},
          id: @subscription_id,
          claims: @claims
        }
      ]
    }

    prev_sub = [
      %{
        channel_pid: :some_prev_pid,
        params: %{"schema" => "public"},
        id: @subscription_id,
        claims: @claims
      }
    ]

    state = %{
      replication_mode: "RLS",
      subscription_params: %{
        some_prev_pid: prev_sub
      },
      sync_interval: 15_000,
      sync_ref: make_ref()
    }

    case SubscriptionManager.handle_call(mess, self(), state) do
      {:reply, :ok, %{subscription_params: sub_param} = new_state} ->
        assert new_state.replication_mode == "RLS"
        assert new_state.sync_interval == 15_000
        assert is_reference(new_state.sync_ref)
        assert sub_param.some_prev_pid == prev_sub

        assert sub_param[self()] == [
                 %{
                   channel_pid: self(),
                   params: %{"schema" => "*"},
                   id: @subscription_id,
                   claims: @claims
                 }
               ]

      other ->
        assert match?({:reply, :ok, _}, other)
    end
  end

  test "handle_info/sync_subscription, recheck" do
    ref = make_ref()
    state = %{sync_ref: ref, sync_interval: 15_000, subscription_params: %{}}

    case SubscriptionManager.handle_info(:sync_subscription, state) do
      {:noreply, new_state} ->
        assert new_state.subscription_params == %{}
        assert new_state.sync_interval == 15_000
        assert new_state.sync_ref != ref
        assert is_reference(new_state.sync_ref)

      other ->
        assert match?({:noreply, _}, other)
    end
  end

  test "handle_info/sync_subscription, when subscription_params is list" do
    state = %{sync_ref: make_ref(), sync_interval: 15_000, subscription_params: []}
    res = SubscriptionManager.handle_info(:sync_subscription, state)
    assert match?({:noreply, _}, res)
  end

  test "handle_info/sync_subscription, when subscription_params is empty" do
    msg = {:DOWN, make_ref(), :process, self(), :any}
    state = %{subscription_params: %{}}
    expected = {:noreply, state}
    assert expected == SubscriptionManager.handle_info(msg, state)
  end

  test "handle_info/sync_subscription, when subscription_params is not empty" do
    msg = {:DOWN, make_ref(), :process, self(), :any}

    state = %{
      subscription_params: %{
        self() => %{
          entities: [],
          filters: [],
          topic: "public:todos",
          id: @subscription_id,
          claims: @claims
        }
      }
    }

    expected = {:noreply, %{subscription_params: %{}}}

    assert expected == SubscriptionManager.handle_info(msg, state)
  end

  test "handle_info, error in Subscriptions.delete_topic_subscriber" do
    with_mock Realtime.RLS.Subscriptions,
      delete_topic_subscriber: fn _ -> raise "" end do
      msg = {:DOWN, make_ref(), :process, self(), :any}

      state = %{
        subscription_params: %{
          self() => %{
            entities: [],
            filters: [],
            topic: "public:todos",
            id: @subscription_id,
            claims: @claims
          }
        }
      }

      expected = {:noreply, %{subscription_params: %{}}}

      assert expected == SubscriptionManager.handle_info(msg, state)
    end
  end
end
