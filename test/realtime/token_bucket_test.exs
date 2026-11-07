defmodule Realtime.TokenBucketTest do
  use ExUnit.Case, async: true

  alias Realtime.TokenBucket

  @second 1_000_000

  describe "take/2" do
    test "starts full and allows a burst" do
      bucket = TokenBucket.new(2, 3, 0)

      assert :ok = TokenBucket.take(bucket, 0)
      assert :ok = TokenBucket.take(bucket, 0)
      assert :ok = TokenBucket.take(bucket, 0)
      assert :error = TokenBucket.take(bucket, 0)
    end

    test "refills at the rate" do
      bucket = TokenBucket.new(2, 1, 0)

      assert :ok = TokenBucket.take(bucket, 0)
      assert :error = TokenBucket.take(bucket, div(@second, 2) - 1)
      assert :ok = TokenBucket.take(bucket, div(@second, 2))
      assert :error = TokenBucket.take(bucket, div(@second, 2))
    end

    test "never holds more than the burst" do
      bucket = TokenBucket.new(2, 3, 0)

      for _ <- 1..3, do: assert(:ok = TokenBucket.take(bucket, 100 * @second))
      assert :error = TokenBucket.take(bucket, 100 * @second)
    end

    test "a rejection does not delay the refill" do
      bucket = TokenBucket.new(1, 1, 0)

      assert :ok = TokenBucket.take(bucket, 0)
      for _ <- 1..10, do: assert(:error = TokenBucket.take(bucket, div(@second, 2)))
      assert :ok = TokenBucket.take(bucket, @second)
    end

    test "works with negative monotonic time" do
      now = -10 * @second
      bucket = TokenBucket.new(1, 1, now)

      assert :ok = TokenBucket.take(bucket, now)
      assert :error = TokenBucket.take(bucket, now)
      assert :ok = TokenBucket.take(bucket, now + @second)
    end

    test "is shared by the processes holding it" do
      bucket = TokenBucket.new(1, 100)

      results =
        1..200
        |> Task.async_stream(fn _ -> TokenBucket.take(bucket) end, max_concurrency: 20)
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &(&1 == :ok)) == 100
      assert Enum.count(results, &(&1 == :error)) == 100
    end
  end
end
