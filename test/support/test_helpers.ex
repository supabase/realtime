defmodule TestHelpers do
  @moduledoc """
  Generic helpers for tests.

  `use TestHelpers` brings these helpers into scope alongside `WaitForIt` and `WaitForIt.Test`;
  the three case templates in `test/support` do this already, so most tests get it for free.
  """

  @default_timeout 5_000
  @default_interval 100

  # `assert_eventually` and `refute_eventually` below shadow their `WaitForIt.Test` namesakes so
  # that they keep this suite's historical wait budget. The arities are derived from
  # `WaitForIt.Test` rather than hardcoded so that an arity added upstream cannot slip past the
  # shadow and silently reintroduce the library's much shorter defaults: it surfaces as an
  # undefined function error here instead.
  @shadowed_assertions for {name, arity} <- WaitForIt.Test.__info__(:macros),
                           name in [:assert_eventually, :refute_eventually],
                           do: {name, arity}

  @doc """
  Imports this module together with `WaitForIt.Test`, and requires `WaitForIt`.

  The waiting assertions that this module overrides with backward-compatible defaults are
  excluded from the `WaitForIt.Test` import; everything else it exports (`assert_always/2`, which
  keeps the library's own 100ms default) comes through untouched.
  """
  defmacro __using__(_opts) do
    quote do
      import TestHelpers
      import WaitForIt.Test, except: unquote(@shadowed_assertions)

      require WaitForIt
    end
  end

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

    wait_for_it_opts =
      opts
      |> Keyword.drop([:retries, :sleep])
      |> Keyword.put_new(:timeout, retries * sleep)
      |> Keyword.put_new(:interval, sleep)

    case WaitForIt.until(fun, wait_for_it_opts) do
      {:ok, _value} -> true
      {:timeout, _last_value} -> false
    end
  end

  @doc """
  Like `WaitForIt.Test.assert_eventually/2`, but defaults `:timeout` to #{@default_timeout}ms and
  `:interval` to #{@default_interval}ms, matching the wait budget of the old
  `retries: 50, sleep: 100` default that this test suite relied on before switching to
  `wait_for_it`. Any options passed here override these defaults.
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

  Note that a passing `refute_eventually` always waits out its whole timeout, so prefer passing a
  shorter `:timeout` where the negative can be established quickly.
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
