defmodule Realtime.GenCounterTest do
  use Realtime.DataCase, async: true

  alias Realtime.GenCounter

  describe "add/1" do
    test "increments a counter" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      assert GenCounter.add(term) == 1
      assert GenCounter.add(term) == 2

      assert GenCounter.get(term) == 2
    end
  end

  describe "add/2" do
    test "increments a counter by `count`" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      assert GenCounter.add(term, 10) == 10
      assert GenCounter.get(term) == 10
    end
  end

  describe "reset/2" do
    test "reset a counter returning the previous value" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      GenCounter.add(term, 10)
      assert 10 == GenCounter.reset(term)
      assert GenCounter.get(term) == 0
      assert :ets.lookup(:gen_counter, term) == [{term, 0}]
    end

    test "reset a counter returning the previous value when counter doesn't exist" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      assert 0 == GenCounter.reset(term)
      assert GenCounter.get(term) == 0
      assert :ets.lookup(:gen_counter, term) == []
    end

    test "reset a counter returning the previous value when counter is 0" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      GenCounter.add(term, 0)
      assert 0 == GenCounter.reset(term)
      assert 0 == GenCounter.reset(term)
      assert GenCounter.get(term) == 0
      assert :ets.lookup(:gen_counter, term) == [{term, 0}]
    end

    test "does not lose adds made while resetting" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      adds = 100_000
      parent = self()

      adder =
        Task.async(fn ->
          for _ <- 1..adds, do: GenCounter.add(term)
          send(parent, :adds_done)
        end)

      reset_total = reset_until_adds_done(term, 0)
      Task.await(adder, 30_000)

      assert reset_total + GenCounter.reset(term) == adds
    end

    test "does not go below 0 when the counter is reset by two processes" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      GenCounter.add(term, 5)

      tasks = for _ <- 1..20, do: Task.async(fn -> GenCounter.reset(term) end)
      Task.await_many(tasks)

      assert GenCounter.get(term) == 0
    end
  end

  describe "delete/1" do
    test "stops the child process the counter is linked to" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      GenCounter.add(term, 10)

      assert GenCounter.delete(term) == :ok
      # When a counter doesn't exist it returns 0
      assert GenCounter.get(term) == 0
    end
  end

  describe "get/1" do
    test "gets the count of a counter" do
      term = {:domain, :metric, Ecto.UUID.generate()}
      assert GenCounter.get(term) == 0

      GenCounter.add(term)

      assert GenCounter.get(term) == 1
    end
  end

  defp reset_until_adds_done(term, total) do
    receive do
      :adds_done -> total
    after
      0 -> reset_until_adds_done(term, total + GenCounter.reset(term))
    end
  end
end
