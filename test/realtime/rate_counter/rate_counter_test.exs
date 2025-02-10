defmodule Realtime.RateCounterTest do
  use Realtime.DataCase

  alias Realtime.RateCounter
  alias Realtime.GenCounter

  describe "new/1" do
    test "starts a new rate counter from an Erlang term" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      assert {:ok, _} = RateCounter.new(term)
    end

    test "rate counters are unique for an Erlang term" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      {:ok, _} = RateCounter.new(term)
      assert {:error, {:already_started, _pid}} = RateCounter.new(term)
    end

    test "rate counters shut themselves down when no activity occurs on the GenCounter" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      {:ok, _} = RateCounter.new(term, idle_shutdown: 5)
      Process.sleep(25)
      assert {:error, _term} = RateCounter.get(term)
    end

    test "rate counters reset GenCounter to zero after one tick and average the bucket" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      {:ok, _} = RateCounter.new(term, tick: 5)
      :ok = GenCounter.add(term)
      Process.sleep(10)

      assert {:ok,
              %RateCounter{
                avg: 0.5,
                bucket: [0, 1],
                id: _id,
                idle_shutdown: 5000,
                idle_shutdown_ref: _ref,
                max_bucket_len: 60,
                tick: 5,
                tick_ref: _ref2
              }} = RateCounter.get(term)
    end
  end

  describe "get/1" do
    test "gets the state of a rate counter" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      {:ok, _} = RateCounter.new(term)

      assert {:ok, %RateCounter{}} = RateCounter.get(term)
    end
  end

  describe "stop/1" do
    test "stops rate counters for a given entity" do
      entity_id = Ecto.UUID.generate()
      fake_terms = Enum.map(1..10, fn _ -> {:domain, :"metric_#{random_string()}", Ecto.UUID.generate()} end)
      terms = Enum.map(1..10, fn _ -> {:domain, :"metric_#{random_string()}", entity_id} end)

      for term <- terms do
        {:ok, _} = RateCounter.new(term)
        assert {:ok, %RateCounter{}} = RateCounter.get(term)
      end

      for term <- fake_terms do
        {:ok, _} = RateCounter.new(term)
        assert {:ok, %RateCounter{}} = RateCounter.get(term)
      end

      assert :ok = RateCounter.stop(entity_id)

      for term <- terms do
        assert {:error, _} = RateCounter.get(term)
      end

      for term <- fake_terms do
        assert {:ok, %RateCounter{}} = RateCounter.get(term)
      end
    end
  end

  test "handle handles counter shutdown and dies" do
    term = {:domain, :metric, Ecto.UUID.generate()}
    {:ok, pid} = RateCounter.new(term)

    assert {:ok, %RateCounter{}} = RateCounter.get(term)
    {_, _, counter_pid} = GenCounter.find_counter(term)
    Process.exit(counter_pid, :shutdown)
    Process.sleep(10)
    refute Process.alive?(pid)
  end
end
