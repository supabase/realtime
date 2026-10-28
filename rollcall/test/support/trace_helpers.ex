defmodule Rollcall.TraceHelpers do
  @moduledoc """
  Helpers for tests that wait for trace points.

  `use Rollcall.TraceHelpers` also does `use Snabbkaffex`. The trace collector
  is global. A test module that uses these helpers must set `async: false`.
  """

  defmacro __using__(_opts) do
    quote do
      use Snabbkaffex
      import Rollcall.TraceHelpers

      # check_trace starts the collector and links it to the test process.
      # The collector stays alive until the test process exits.
      # The next test can find a collector that is about to stop.
      # Stop the collector after each test.
      setup do
        on_exit(&Snabbkaffex.stop/0)
      end
    end
  end

  @doc """
  Returns the events in `trace` that have one of `kinds` and the given `scope`.
  """
  def events(trace, kinds, scope) do
    trace
    |> Snabbkaffex.of_kind(kinds)
    |> Enum.filter(&(&1.scope == scope))
  end

  @doc """
  Returns the reference of the empty timer of `tracker`.

  Raises when the tracker has no empty timer.
  """
  def empty_timer(tracker) do
    case :sys.get_state(tracker) do
      %{empty_timer: nil} -> raise "the tracker has no empty timer"
      %{empty_timer: ref} -> ref
    end
  end

  @doc """
  Sends the timeout message of the empty timer to `tracker`, as if the timer
  expired.

  A test that uses this function does not wait for the grace period, so the
  test does not depend on timing.
  """
  def expire_grace(tracker) do
    send(tracker, {:timeout, empty_timer(tracker), :empty_timeout})
  end

  @doc """
  Runs the block, then waits for a trace event that matches `pattern`.

  Returns the value of the block. Fails the test when no matching event
  arrives within `timeout` milliseconds. The default timeout is 1000.

  The failure message shows the pattern and the value of each pinned variable.
  """
  defmacro wait_for_event(pattern, opts \\ [], do: block) do
    pattern_text = Macro.to_string(pattern)
    pins = pins(pattern)
    timeout = Keyword.get(opts, :timeout, 1_000)

    quote do
      require Snabbkaffex

      {block_value, outcome} =
        Snabbkaffex.wait_async_action(unquote(pattern), [timeout: unquote(timeout)], do: unquote(block))

      case outcome do
        {:ok, _event} ->
          block_value

        :timeout ->
          ExUnit.Assertions.flunk(
            Rollcall.TraceHelpers.timeout_message(
              unquote(pattern_text),
              unquote(pins),
              unquote(timeout),
              block_value
            )
          )
      end
    end
  end

  @doc false
  def timeout_message(pattern_text, pins, timeout, block_value) do
    """
    No trace event matched within #{timeout} ms.

    Pattern:
        #{pattern_text}
    #{format_pins(pins)}
    The block returned: #{inspect(block_value)}

    snabbkaffe writes the events that arrived to a dump file. The log shows the path.
    """
  end

  defp format_pins([]), do: ""

  defp format_pins(pins) do
    values = Enum.map_join(pins, "\n", fn {name, value} -> "    #{name} = #{inspect(value)}" end)
    "Where:\n" <> values <> "\n"
  end

  # Returns the AST of a list of {name, value} pairs, one for each variable that
  # the pattern pins with `^`.
  defp pins(pattern) do
    {_pattern, pins} =
      Macro.prewalk(pattern, [], fn
        {:^, _meta, [{name, _var_meta, context} = var]} = node, acc
        when is_atom(name) and is_atom(context) ->
          {node, [{Atom.to_string(name), var} | acc]}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(pins)
  end
end
