defmodule TestHelpers do
  @moduledoc """
  Generic helpers for tests.
  """

  @doc """
  Runs `fun` until it returns a truthy value, retrying until it succeeds or the timeout is reached.

  Returns `true` if `fun` succeeded or `false` if it timed out.

  This now uses `WaitForIt.until/2` under the hood, so you can pass any options that it accepts.

  ## Options

    * `:timeout` - the amount of time to wait (in milliseconds) before giving up, or `:infinity`
      to wait indefinitely
    * `:interval` - the polling interval in milliseconds, or a
      [`WaitForIt.Backoff`](https://hexdocs.pm/wait_for_it/2.5.0/WaitForIt.Backoff.html) function
    * `:pre_wait` - wait for the given number of milliseconds before evaluating for the first time
    * `:signal` - disable polling and use a signal of the given name instead

  ### Deprecated Options

  If the following options are provided, they will be converted to the new options above.
  If `:sleep` is provided, it will be used as the `:interval` option. If `:retries` is provided,
  it will be used to calculate the `:timeout` option.

    * `:retries` - the number of times to retry before giving up (default: 50)
    * `:sleep` - the amount of time to sleep between retries (default: 100)
  """
  @spec eventually((-> as_boolean(term())), keyword()) :: boolean()
  def eventually(fun, opts \\ []) do
    retries = Keyword.get(opts, :retries, 50)
    sleep = Keyword.get(opts, :sleep, 100)
    timeout = Keyword.get(opts, :timeout, retries * sleep)
    interval = Keyword.get(opts, :interval, sleep)

    wait_for_it_opts =
      opts
      |> Keyword.drop([:retries, :sleep])
      |> Keyword.put_new(:timeout, timeout)
      |> Keyword.put_new(:interval, interval)

    case WaitForIt.until(fun, wait_for_it_opts) do
      {:ok, _value} -> true
      {:timeout, _last_value} -> false
    end
  end

  @default_timeout 5_000
  @default_interval 100

  @doc """
  Like `WaitForIt.Test.assert_eventually/2`, but defaults `:timeout` to 5000ms and `:interval`
  to 100ms, matching the wait budget of the old `retries: 50, sleep: 100` default that this test
  suite relied on before switching to `wait_for_it`. Any options passed here override these
  defaults.
  """
  defmacro assert_eventually(expression, opts \\ []) do
    quote do
      require WaitForIt.Test
      WaitForIt.Test.assert_eventually(unquote(expression), TestHelpers.__with_defaults__(unquote(opts)))
    end
  end

  @doc """
  Like `WaitForIt.Test.refute_eventually/2`, but with the same backward-compatible `:timeout`
  and `:interval` defaults as `assert_eventually/2`.
  """
  defmacro refute_eventually(expression, opts \\ []) do
    quote do
      require WaitForIt.Test
      WaitForIt.Test.refute_eventually(unquote(expression), TestHelpers.__with_defaults__(unquote(opts)))
    end
  end

  @doc false
  def __with_defaults__(opts) do
    opts
    |> Keyword.put_new(:timeout, @default_timeout)
    |> Keyword.put_new(:interval, @default_interval)
  end
end
