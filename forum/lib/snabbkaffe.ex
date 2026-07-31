defmodule Snabbkaffe do
  @moduledoc """
  Elixir interface to the Erlang [snabbkaffe](https://github.com/kafka4beam/snabbkaffe)
  trace-based testing library.

  Snabbkaffe ships its instrumentation as Erlang preprocessor macros
  (`-include_lib("snabbkaffe/include/trace.hrl")`) which are not usable from
  Elixir. This module provides the Elixir macro counterparts so that:

    * **Trace points** placed in production code (`tp/2`, `tp/3`, `tp_span/3`,
      `tp_span/4`) are *discarded* when compiled outside of the test environment
      (exactly like the Erlang `trace_prod.hrl` no-ops) and only become real
      snabbkaffe calls in `:test`.
    * **Test helpers** (`check_trace/2`, `block_until/2`, `of_kind/2`, ...) wrap
      the corresponding `:snabbkaffe` runtime calls. Most are plain functions;
      only the ones that take an Elixir *pattern* (`block_until`, `find_pairs`,
      `causality`, `force_ordering`, ...) need to be macros: they turn the
      pattern into a matcher function in place of snabbkaffe's `?match_event`.

  ## Why discard in prod?

  Snabbkaffe is a test-only dependency (`only: :test`). The trace-point macros
  live in regular `lib/` code, so they must compile to a cheap no-op when the
  collector is not present. Following snabbkaffe's own convention, the gate is
  `Mix.env() == :test`, evaluated *at macro-expansion time* so it reflects the
  environment of the module being compiled.

  To match the Erlang semantics precisely, the discarded `tp/2` still *evaluates*
  its data expression (so side effects behave identically across builds) and then
  throws the value away. `tp/3` (with an explicit log level) degrades to a
  `:logger` call in non-test builds, just like `trace_prod.hrl`.

  ## Usage

      defmodule MyServer do
        use Snabbkaffe

        def handle_event(e) do
          tp(:my_server_got_event, %{event: e})
          # ...
        end
      end

  And in a test:

      use Snabbkaffe

      test "server processes the event" do
        check_trace(
          fn -> MyServer.handle_event(:hello) end,
          fn trace ->
            assert [%{event: :hello}] = of_kind(:my_server_got_event, trace)
          end
        )
      end

  ## Event shape

  A trace point `tp(:kind, %{a: 1})` is collected as a map
  `%{:"$kind" => :kind, :a => 1, :"~meta" => %{...}}`. When pattern matching on
  events, the kind lives under the `:"$kind"` key. Prefer `of_kind/2` to filter
  by kind so you rarely need to spell that out.
  """

  # snabbkaffe's well-known map keys (see include/common.hrl).
  # The leading "$" makes the kind sort first when maps are printed; collected
  # events also carry metadata under the `:"~meta"` key.
  @snk_kind :"$kind"
  @snk_span :"$span"

  @doc """
  Imports and requires `Snabbkaffe`, bringing all trace/test macros and helper
  functions into scope.
  """
  defmacro __using__(_opts) do
    quote do
      require Snabbkaffe
      import Snabbkaffe
    end
  end

  ##
  ## Trace points (discardable outside :test)
  ##

  @doc """
  Emit a trace point of the given `kind` carrying `data` (a map).

  In `:test` this records an event via the snabbkaffe collector. In any other
  environment it evaluates `data` (preserving side effects) and returns `:ok`.
  """
  defmacro tp(kind, data) do
    build_tp(:debug, kind, data, false, __CALLER__)
  end

  @doc """
  Emit a trace point at an explicit log `level` (e.g. `:debug`, `:error`).

  In `:test` this records an event. Outside `:test` it degrades to a `:logger`
  call (matching snabbkaffe's `trace_prod.hrl`), so the event is still observable
  in production logs.
  """
  defmacro tp(level, kind, data) do
    build_tp(level, kind, data, true, __CALLER__)
  end

  @doc """
  Trace a span around `block`: emits a `start` event before and a
  `{:complete, return}` event after, then returns the block's value.

  Mirrors snabbkaffe's `?tp_span/3`; the discardable rules of `tp/2` apply.
  """
  defmacro tp_span(kind, data, do: block) do
    quote do
      Snabbkaffe.tp(unquote(kind), Map.put(unquote(data), unquote(@snk_span), :start))
      ret = unquote(block)
      Snabbkaffe.tp(unquote(kind), Map.put(unquote(data), unquote(@snk_span), {:complete, ret}))
      ret
    end
  end

  @doc """
  Span variant with an explicit log `level` (degrades to logging in prod).
  """
  defmacro tp_span(level, kind, data, do: block) do
    quote do
      Snabbkaffe.tp(
        unquote(level),
        unquote(kind),
        Map.put(unquote(data), unquote(@snk_span), :start)
      )

      ret = unquote(block)

      Snabbkaffe.tp(
        unquote(level),
        unquote(kind),
        Map.put(unquote(data), unquote(@snk_span), {:complete, ret})
      )

      ret
    end
  end

  ##
  ## Running a trace + checking it
  ##

  @doc """
  Run `run_fun`, collect the resulting trace, then validate it with `check_fun`.

  `run_fun` is a zero-arity function whose return value becomes the test result.
  `check_fun` is a function of either arity 1 (`trace`) or arity 2
  (`result, trace`). The check **passes unless it raises**: use ordinary ExUnit
  assertions; the function's return value is ignored (unlike Erlang snabbkaffe,
  which requires `true`/`ok`).

      check_trace(
        fn -> do_work() end,
        fn result, trace ->
          assert result == :ok
          assert [_] = of_kind(:work_done, trace)
        end
      )
  """
  def check_trace(run_fun, check_fun), do: check_trace(%{}, run_fun, check_fun)

  @doc """
  `check_trace/2` with a snabbkaffe run config (a map, e.g. `%{timeout: 100}`) or
  an integer statistics bucket.
  """
  def check_trace(config, run_fun, check_fun) do
    __check__(:snabbkaffe.run(config, run_fun, __wrap_check__(check_fun)))
  end

  @doc false
  # Coerce a user check fun to snabbkaffe's "return true/ok to pass" contract:
  # in Elixir a check passes by not raising, so we discard its return value.
  def __wrap_check__(fun) when is_function(fun, 1) do
    fn trace ->
      fun.(trace)
      true
    end
  end

  def __wrap_check__(fun) when is_function(fun, 2) do
    fn result, trace ->
      fun.(result, trace)
      true
    end
  end

  @doc false
  def __check__(true), do: true
  def __check__(:ok), do: true

  def __check__({:error, {:panic, kind, args}}) do
    raise "snabbkaffe panic: #{inspect(kind)} #{inspect(args)}"
  end

  def __check__(other) do
    raise "snabbkaffe check_trace failed: #{inspect(other)}"
  end

  ##
  ## Collector lifecycle
  ##

  @doc "Start the snabbkaffe collector (idempotent)."
  def start_trace, do: :snabbkaffe.start_trace()

  @doc "Stop the snabbkaffe collector."
  def stop, do: :snabbkaffe.stop()

  @doc "Flush and return the collected trace, waiting `timeout` ms for silence first."
  def collect_trace(timeout \\ 0), do: :snabbkaffe.collect_trace(timeout)

  ##
  ## Synchronisation
  ##

  @doc """
  Block until an event matching `pattern` is collected, or until `timeout`.

  `back_in_time` (ms) lets the matcher also consider recently-collected events,
  avoiding a race when the event fires before the call. Returns
  `{:ok, event}` or `:timeout`.
  """
  defmacro block_until(pattern, timeout \\ :infinity, back_in_time \\ :infinity) do
    quote do
      :snabbkaffe.block_until(
        unquote(matcher(pattern)),
        unquote(timeout),
        unquote(back_in_time)
      )
    end
  end

  @doc """
  `block_until/3` waiting for `n_events` events matching `pattern` (mirrors
  Erlang's `?block_until({Predicate, NEvents}, ...)` form). Events already in
  the collected trace count towards `n_events`, which makes it the right tool
  for waiting on the Nth occurrence of a recurring event (e.g. a node becoming
  `:ready` for the same view a second time, after churn). Returns
  `{:ok, [event]}` or `{:timeout, [partial]}`.
  """
  defmacro block_until(pattern, n_events, timeout, back_in_time) do
    quote do
      :snabbkaffe.block_until(
        {unquote(matcher(pattern)), unquote(n_events)},
        unquote(timeout),
        unquote(back_in_time)
      )
    end
  end

  @doc """
  Subscribe to an event matching `pattern`, run `action_fun`, then wait (up to
  `timeout`) for the event. Returns `{action_return, {:ok, event} | :timeout}`.
  """
  defmacro wait_async_action(action_fun, pattern, timeout \\ :infinity) do
    quote do
      :snabbkaffe.wait_async_action(
        unquote(action_fun),
        unquote(matcher(pattern)),
        unquote(timeout)
      )
    end
  end

  @doc """
  Retry `fun` up to `n` times, sleeping `interval` ms between attempts, until it
  stops raising. Returns the function's value.
  """
  def retry(interval, n, fun), do: :snabbkaffe.retry(interval, n, fun)

  ##
  ## Trace querying
  ##

  @doc "Keep only events whose `:\"$kind\"` is `kind` (or one of a list of kinds)."
  def of_kind(kind, trace), do: :snabbkaffe.events_of_kind(kind, trace)

  @doc """
  Project `field` (atom) or `fields` (list of atoms) out of each event.

  With a single atom, returns a list of values; with a list, a list of tuples.
  """
  def projection(fields, trace), do: :snabbkaffe.projection(fields, trace)

  @doc """
  Find cause/effect pairs of events matching `cause_pattern` and `effect_pattern`.
  """
  defmacro find_pairs(cause_pattern, effect_pattern, trace) do
    build_find_pairs(cause_pattern, effect_pattern, true, trace)
  end

  @doc "`find_pairs/3` with an extra `guard` expression over both events' bindings."
  defmacro find_pairs(cause_pattern, effect_pattern, guard, trace) do
    build_find_pairs(cause_pattern, effect_pattern, guard, trace)
  end

  @doc """
  Assert every effect event was preceded by a matching cause event. Pairs may be
  nested. Raises on a causality violation; otherwise returns `true` if at least
  one pair was found, `false` if none.
  """
  defmacro causality(cause_pattern, effect_pattern, trace) do
    do_causality(false, cause_pattern, effect_pattern, true, trace)
  end

  @doc "`causality/3` with a `guard` expression over both events' bindings."
  defmacro causality(cause_pattern, effect_pattern, guard, trace) do
    do_causality(false, cause_pattern, effect_pattern, guard, trace)
  end

  @doc "Like `causality/3`, but additionally forbids unmatched effect events."
  defmacro strict_causality(cause_pattern, effect_pattern, trace) do
    do_causality(true, cause_pattern, effect_pattern, true, trace)
  end

  @doc "`strict_causality/3` with a `guard` expression over both events' bindings."
  defmacro strict_causality(cause_pattern, effect_pattern, guard, trace) do
    do_causality(true, cause_pattern, effect_pattern, guard, trace)
  end

  ##
  ## Fault injection / scheduling (snabbkaffe_nemesis)
  ##

  @doc """
  Delay events matching `delayed_pattern` until an event matching
  `continue_pattern` has been emitted, enforcing an ordering between them.
  """
  defmacro force_ordering(continue_pattern, delayed_pattern) do
    build_force_ordering(continue_pattern, 1, delayed_pattern, true)
  end

  @doc "`force_ordering/2` with a `guard` expression over (delayed, continue)."
  defmacro force_ordering(continue_pattern, delayed_pattern, guard) do
    build_force_ordering(continue_pattern, 1, delayed_pattern, guard)
  end

  @doc """
  `force_ordering/3` releasing only after `n_events` events matching
  `continue_pattern` have been emitted (mirrors Erlang's
  `?force_ordering(CONTINUE, N_EVENTS, DELAYED, GUARD)`). Events already in
  the collected trace count towards `n_events`.
  """
  defmacro force_ordering(continue_pattern, n_events, delayed_pattern, guard) do
    build_force_ordering(continue_pattern, n_events, delayed_pattern, guard)
  end

  @doc """
  Inject crashes at trace points matching `pattern`.

  `strategy` is a snabbkaffe crash strategy such as `{:recover, n, prob}` or
  `:always`; `reason` is the error term to raise (defaults to `:notmyday`).
  """
  defmacro inject_crash(pattern, strategy, reason \\ :notmyday) do
    quote do
      :snabbkaffe_nemesis.inject_crash(
        unquote(matcher(pattern)),
        unquote(strategy),
        unquote(reason)
      )
    end
  end

  ##
  ## Assertions
  ##

  @doc """
  Assert `value` is within `deviation` of `expected`. Returns `true` or raises.
  """
  def give_or_take(expected, deviation, value)
      when is_number(expected) and is_number(deviation) and is_number(value) do
    if abs(value - expected) <= deviation do
      true
    else
      raise "give_or_take failed: expected #{inspect(value)} to be within " <>
              "#{inspect(deviation)} of #{inspect(expected)}"
    end
  end

  @doc """
  Build a predicate `fn event -> boolean end` from an Elixir `pattern`.

  This is the Elixir counterpart of snabbkaffe's `?match_event`, used internally
  by the pattern-taking macros and exposed for building snabbkaffe subscriptions
  directly (`:snabbkaffe.subscribe/1`, etc.).
  """
  defmacro match_event(pattern) do
    matcher(pattern)
  end

  ##
  ## Expansion-time helpers (run while a *caller* is being compiled)
  ##

  # Whether trace points should expand to live snabbkaffe calls. Evaluated inside
  # macro bodies, so `Mix.env/0` is the environment of the module being compiled.
  defp collector_enabled? do
    function_exported?(Mix, :env, 0) and Mix.env() == :test
  end

  defp build_tp(level, kind, data, explicit_level?, caller) do
    if collector_enabled?() do
      quote do
        :snabbkaffe.tp(
          unquote(static_token(caller)),
          unquote(level),
          unquote(kind),
          unquote(data)
        )
      end
    else
      prod_tp(level, kind, data, explicit_level?, caller)
    end
  end

  # Non-test expansion, mirroring snabbkaffe's trace_prod.hrl:
  #   ?tp(KIND, EVT)        -> begin _ = EVT, ok end   (pure discard)
  #   ?tp(LEVEL, KIND, EVT) -> logger:log(LEVEL, EVT#{kind => KIND}, Meta)
  defp prod_tp(_level, _kind, data, false, _caller) do
    quote do
      _ = unquote(data)
      :ok
    end
  end

  defp prod_tp(level, kind, data, true, caller) do
    meta = log_metadata(caller)

    quote do
      :logger.log(
        unquote(level),
        Map.put(unquote(data), unquote(@snk_kind), unquote(kind)),
        unquote(Macro.escape(meta))
      )
    end
  end

  # snabbkaffe's ?__snkStaticUniqueToken: a fresh `fn -> {file, line} end` per call
  # site. Used as a stable identity for crash-injection points and trace dumps.
  defp static_token(caller) do
    quote do: fn -> {unquote(caller.file), unquote(caller.line)} end
  end

  defp log_metadata(caller) do
    base = %{line: caller.line, file: caller.file}

    case caller.function do
      {name, arity} -> Map.put(base, :mfa, {caller.module, name, arity})
      nil -> base
    end
  end

  # ?match_event(PATTERN): fn event -> match?(PATTERN, event) end
  defp matcher(pattern) do
    quote do
      fn __snk_event__ -> match?(unquote(pattern), __snk_event__) end
    end
  end

  # ?snk_int_match_arg2(M1, M2, GUARD): a 2-arity predicate that matches the first
  # arg against `m1`, the second against `m2`, then evaluates `guard` (an ordinary
  # boolean expression, not an Elixir guard) with the bindings from both patterns.
  defp matcher2(m1, m2, guard) do
    quote do
      fn __snk_a__, __snk_b__ ->
        case __snk_a__ do
          unquote(m1) ->
            case __snk_b__ do
              unquote(m2) -> unquote(guard)
              _ -> false
            end

          _ ->
            false
        end
      end
    end
  end

  defp do_causality(strict?, cause_pattern, effect_pattern, guard, trace) do
    quote do
      :snabbkaffe.causality(
        unquote(strict?),
        unquote(matcher(cause_pattern)),
        unquote(matcher(effect_pattern)),
        unquote(matcher2(cause_pattern, effect_pattern, guard)),
        unquote(trace)
      )
    end
  end

  defp build_find_pairs(cause_pattern, effect_pattern, guard, trace) do
    quote do
      :snabbkaffe.find_pairs(
        unquote(matcher(cause_pattern)),
        unquote(matcher(effect_pattern)),
        unquote(matcher2(cause_pattern, effect_pattern, guard)),
        unquote(trace)
      )
    end
  end

  # ?force_ordering(CONTINUE, N, DELAYED, GUARD): hold back DELAYED events until
  # N CONTINUE events have fired. Note the matcher argument order (delayed first).
  defp build_force_ordering(continue_pattern, n_events, delayed_pattern, guard) do
    quote do
      :snabbkaffe_nemesis.force_ordering(
        unquote(matcher(delayed_pattern)),
        unquote(n_events),
        unquote(matcher2(delayed_pattern, continue_pattern, guard))
      )
    end
  end
end
