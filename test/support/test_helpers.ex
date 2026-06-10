defmodule TestHelpers do
  @moduledoc """
  Generic helpers for tests.
  """

  @doc """
  Runs `fun` until it returns a truthy value, retrying until it runs out of retries.
  Returns `true` if `fun` succeeded within the retries, `false` otherwise.

  ## Options

    * `:retries` - how many times to retry before giving up (default: `50`)
    * `:sleep` - how long to wait between retries, in milliseconds (default: `100`)
  """
  @spec eventually((-> as_boolean(term())), keyword()) :: boolean()
  def eventually(fun, opts \\ []) do
    retries = Keyword.get(opts, :retries, 50)
    sleep = Keyword.get(opts, :sleep, 100)

    cond do
      fun.() ->
        true

      retries == 0 ->
        false

      true ->
        opts = Keyword.put(opts, :retries, retries - 1)
        Process.sleep(sleep)
        eventually(fun, opts)
    end
  end
end
