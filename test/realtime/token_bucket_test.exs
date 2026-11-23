defmodule Realtime.TokenBucketTest do
  use ExUnit.Case, async: true

  alias Realtime.TokenBucket

  @second 1_000_000

  describe "take/2" do
    test "starts full and allows a burst" do
      bucket = TokenBucket.per_second(3, 2, 0)

      assert :ok = TokenBucket.take(bucket, 0)
      assert :ok = TokenBucket.take(bucket, 0)
      assert :ok = TokenBucket.take(bucket, 0)
      assert :error = TokenBucket.take(bucket, 0)
    end

    test "refills at the rate" do
      bucket = TokenBucket.per_second(1, 2, 0)

      assert :ok = TokenBucket.take(bucket, 0)
      assert :error = TokenBucket.take(bucket, div(@second, 2) - 1)
      assert :ok = TokenBucket.take(bucket, div(@second, 2))
      assert :error = TokenBucket.take(bucket, div(@second, 2))
    end

    test "never holds more than the burst" do
      bucket = TokenBucket.per_second(3, 2, 0)

      for _ <- 1..3, do: assert(:ok = TokenBucket.take(bucket, 100 * @second))
      assert :error = TokenBucket.take(bucket, 100 * @second)
    end

    test "a rejection does not delay the refill" do
      bucket = TokenBucket.per_second(1, 1, 0)

      assert :ok = TokenBucket.take(bucket, 0)
      for _ <- 1..10, do: assert(:error = TokenBucket.take(bucket, div(@second, 2)))
      assert :ok = TokenBucket.take(bucket, @second)
    end

    test "works with negative monotonic time" do
      now = -10 * @second
      bucket = TokenBucket.per_second(1, 1, now)

      assert :ok = TokenBucket.take(bucket, now)
      assert :error = TokenBucket.take(bucket, now)
      assert :ok = TokenBucket.take(bucket, now + @second)
    end

    test "is shared by the processes holding it" do
      bucket = TokenBucket.per_second(100, 1)

      results =
        1..200
        |> Task.async_stream(fn _ -> TokenBucket.take(bucket) end, max_concurrency: 20)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 100
      assert Enum.count(results, &(&1 == :error)) == 100
    end
  end

  describe "wait_time/2" do
    test "is 0 while the bucket has a token" do
      bucket = TokenBucket.per_second(2, 2, 0)

      assert TokenBucket.wait_time(bucket, 0) == 0
      assert :ok = TokenBucket.take(bucket, 0)
      assert TokenBucket.wait_time(bucket, 0) == 0
    end

    test "is the time until the next take fits" do
      bucket = TokenBucket.per_second(2, 2, 0)

      assert :ok = TokenBucket.take(bucket, 0)
      assert :ok = TokenBucket.take(bucket, 0)
      assert TokenBucket.wait_time(bucket, 0) == div(@second, 2)
      assert TokenBucket.wait_time(bucket, div(@second, 4)) == div(@second, 4)

      assert :error = TokenBucket.take(bucket, div(@second, 2) - 1)
      assert :ok = TokenBucket.take(bucket, div(@second, 2))
    end

    test "a rejection does not make the wait longer" do
      bucket = TokenBucket.per_second(1, 1, 0)

      assert :ok = TokenBucket.take(bucket, 0)
      for _ <- 1..10, do: assert(:error = TokenBucket.take(bucket, 0))
      assert TokenBucket.wait_time(bucket, 0) == @second
    end
  end

  describe "per_second/3" do
    test "refills one token every 1 / rate seconds" do
      assert %TokenBucket{interval: 10_000, tolerance: 9_990_000} = TokenBucket.per_second(1_000, 100)
      assert %TokenBucket{interval: 333_333} = TokenBucket.per_second(1, 3)
    end

    test "refills at most 1,000,000 tokens per second" do
      assert %TokenBucket{interval: 1} = TokenBucket.per_second(1, 1_000_000)
      assert %TokenBucket{interval: 1, tolerance: 1} = TokenBucket.per_second(2, 5_000_000)
    end
  end

  describe "per_window/4" do
    test "holds the count and refills one token every window / count" do
      bucket = TokenBucket.per_window(5, 30_000, :millisecond, 0)

      for _ <- 1..5, do: assert(:ok = TokenBucket.take(bucket, 0))
      assert :error = TokenBucket.take(bucket, 0)

      assert :error = TokenBucket.take(bucket, 6 * @second - 1)
      assert :ok = TokenBucket.take(bucket, 6 * @second)
      assert :error = TokenBucket.take(bucket, 6 * @second)
    end

    test "is full again after the window" do
      bucket = TokenBucket.per_window(5, 30_000, :millisecond, 0)

      for _ <- 1..5, do: assert(:ok = TokenBucket.take(bucket, 0))
      for _ <- 1..5, do: assert(:ok = TokenBucket.take(bucket, 30 * @second))
      assert :error = TokenBucket.take(bucket, 30 * @second)
    end

    test "takes any time unit" do
      assert %TokenBucket{interval: 6_000_000} = TokenBucket.per_window(5, 30, :second)
      assert %TokenBucket{interval: 33_333} = TokenBucket.per_window(3, 100, :millisecond)
    end

    test "refills at most one token per microsecond" do
      assert %TokenBucket{interval: 1} = TokenBucket.per_window(10, 5, :microsecond)
    end
  end
end
