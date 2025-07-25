defmodule Realtime.RateCounterTest do
  use Realtime.DataCase, async: true

  alias Realtime.RateCounter
  alias Realtime.GenCounter

  describe "new/1" do
    test "starts a new rate counter from an Erlang term" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      assert {:ok, _} = RateCounter.new(term)
    end

    test "reset counter if GenCounter already had something" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      GenCounter.add(term, 100)
      assert {:ok, _} = RateCounter.new(term)
      assert GenCounter.get(term) == 0
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
      assert GenCounter.add(term) == 1
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

      assert GenCounter.get(term) == 0
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
end
