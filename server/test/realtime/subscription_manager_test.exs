defmodule Realtime.SubscriptionManagerTest do
  use ExUnit.Case
  import Mock
  alias Realtime.RLS.Repo
  alias Realtime.SubscriptionManager

  @user_id "bbb51e4e-f371-4463-bf0a-af8f56dc9a71"

  setup_all do
    start_supervised(Realtime.RLS.Repo)
    :ok
  end

  test "track_topic_subscriber/1" do
    mess = {
      :track_topic_subscriber,
      %{
        channel_pid: self(),
        topic: "test_topic",
        user_id: @user_id
      }
    }

    assert :ok == SubscriptionManager.track_topic_subscriber(mess)
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

  test "handle_call/track_topic_subscriber, when subscription_params is empty" do
    mess = {
      :track_topic_subscriber,
      %{
        channel_pid: self(),
        topic: "test_topic",
        user_id: @user_id
      }
    }

    state = %{replication_mode: "RLS", subscription_params: %{}}
    expected = {:reply, :error, %{replication_mode: "RLS", subscription_params: %{}}}
    assert expected == SubscriptionManager.handle_call(mess, self(), state)
  end

  test "handle_call/track_topic_subscriber, when subscription_params is not empty" do
    mess = {
      :track_topic_subscriber,
      %{
        channel_pid: self(),
        topic: "test_topic",
        user_id: @user_id
      }
    }

    state = %{
      replication_mode: "RLS",
      subscription_params: %{
        self() => %{
          entities: [16537],
          filters: [],
          topic: "public:todos",
          user_id: <<187, 181, 30, 78, 243, 113, 68, 99, 191, 10, 175, 143, 86, 220, 154, 115>>
        }
      },
      sync_interval: 15_000,
      sync_ref: make_ref()
    }

    expected = {:reply, :ok, state}
    assert expected == SubscriptionManager.handle_call(mess, self(), state)
  end

  test "handle_call/track_topic_subscriber, updated state" do
    {_, bin} = Ecto.UUID.dump(@user_id)
    Repo.query("insert into auth.users (id) values ($1)", [bin])

    mess = {
      :track_topic_subscriber,
      %{
        channel_pid: self(),
        topic: "test_topic",
        user_id: bin
      }
    }

    prev_sub = %{
      entities: [16537],
      filters: [],
      topic: "public:todos",
      user_id: bin
    }

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

        assert sub_param[self()] == %{
                 entities: [],
                 filters: [],
                 topic: "test_topic",
                 user_id: bin
               }

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
    {_, bin} = Ecto.UUID.dump(@user_id)

    state = %{
      subscription_params: %{
        self() => %{
          entities: [],
          filters: [],
          topic: "public:todos",
          user_id: bin
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
      {_, bin} = Ecto.UUID.dump(@user_id)

      state = %{
        subscription_params: %{
          self() => %{
            entities: [],
            filters: [],
            topic: "public:todos",
            user_id: bin
          }
        }
      }

      expected = {:noreply, %{subscription_params: %{}}}

      assert expected == SubscriptionManager.handle_info(msg, state)
    end
  end
end
