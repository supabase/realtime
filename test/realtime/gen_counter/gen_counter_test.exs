defmodule Realtime.GenCounterTest do
  use Realtime.DataCase

  alias Realtime.GenCounter

  describe "new/1" do
    test "starts a new counter from an Erlang term" do
      term = Ecto.UUID.generate()
      assert {:ok, _} = GenCounter.new(term)
    end

    test "counters are unique for an Erlang term" do
      term = Ecto.UUID.generate()
      {:ok, _} = GenCounter.new(term)
      assert {:error, {:already_started, _pid}} = GenCounter.new(term)
    end
  end

  describe "add/1" do
    test "incriments a counter" do
      term = Ecto.UUID.generate()
      {:ok, _} = GenCounter.new(term)
      :ok = GenCounter.add(term)
      assert {:ok, 1} = GenCounter.get(term)
    end
  end

  describe "add/2" do
    test "incriments a counter by `count`" do
      term = Ecto.UUID.generate()
      {:ok, _} = GenCounter.new(term)
      :ok = GenCounter.add(term, 10)
      assert {:ok, 10} = GenCounter.get(term)
    end
  end

  describe "sub/1" do
    test "decriments a counter" do
      term = Ecto.UUID.generate()
      {:ok, _} = GenCounter.new(term)
      :ok = GenCounter.add(term)
      :ok = GenCounter.sub(term)
      assert {:ok, 0} = GenCounter.get(term)
    end
  end

  describe "sub/2" do
    test "decriments a counter by `count`" do
      term = Ecto.UUID.generate()
      {:ok, _} = GenCounter.new(term)
      :ok = GenCounter.add(term, 10)
      :ok = GenCounter.sub(term, 5)
      assert {:ok, 5} = GenCounter.get(term)
    end
  end

  describe "put/2" do
    test "replactes a counter with `count`" do
      term = Ecto.UUID.generate()
      {:ok, _} = GenCounter.new(term)
      :ok = GenCounter.put(term, 10)
      assert {:ok, 10} = GenCounter.get(term)
    end
  end

  describe "stop/2" do
    test "stops the child process the counter is linked to" do
      term = Ecto.UUID.generate()
      {:ok, _} = GenCounter.new(term)
      :ok = GenCounter.stop(term)
      Process.sleep(100)
      assert :error = GenCounter.info(term)
    end
  end

  describe "info/2" do
    test "gets some info on a counter" do
      term = Ecto.UUID.generate()
      {:ok, _} = GenCounter.new(term)
      assert %{memory: _mem, size: _size} = GenCounter.info(term)
    end
  end

  describe "get/1" do
    test "gets the count of a counter" do
      term = Ecto.UUID.generate()
      {:ok, _} = GenCounter.new(term)
      assert {:ok, 0} = GenCounter.get(term)
    end
  end
end
