defmodule SnabbkaffeTest do
  use ExUnit.Case, async: false
  use Snabbkaffe

  # A bit of "production" code instrumented with trace points. In :test these
  # become real snabbkaffe events; in any other env they would be discarded.
  defmodule Worker do
    use Snabbkaffe

    def do_work(input) do
      tp(:worker_started, %{input: input})
      result = input * 2
      tp(:worker_finished, %{input: input, result: result})
      result
    end

    def span_work(input) do
      tp_span :worker_span, %{input: input} do
        input + 1
      end
    end

    def ping_after(ms, ref) do
      spawn(fn ->
        Process.sleep(ms)
        tp(:pong, %{ref: ref})
      end)

      :scheduled
    end
  end

  describe "tp + check_trace" do
    test "trace points are collected and queryable by kind" do
      check_trace(
        fn -> Worker.do_work(21) end,
        fn result, trace ->
          assert result == 42
          assert [%{input: 21}] = of_kind(:worker_started, trace)
          assert [%{input: 21, result: 42}] = of_kind(:worker_finished, trace)
        end
      )
    end

    test "events carry the $kind key and meta" do
      check_trace(
        fn -> Worker.do_work(1) end,
        fn trace ->
          assert [event] = of_kind(:worker_started, trace)
          assert %{:"$kind" => :worker_started, :"~meta" => meta} = event
          assert is_map(meta)
        end
      )
    end

    test "projection extracts fields across events" do
      check_trace(
        fn ->
          Worker.do_work(2)
          Worker.do_work(3)
        end,
        fn trace ->
          inputs = projection(:input, of_kind(:worker_started, trace))
          assert inputs == [2, 3]
        end
      )
    end
  end

  describe "tp_span" do
    test "emits start and complete events and returns the block value" do
      check_trace(
        fn -> Worker.span_work(10) end,
        fn result, trace ->
          assert result == 11

          assert [%{:"$span" => :start}, %{:"$span" => {:complete, 11}}] =
                   of_kind(:worker_span, trace)
        end
      )
    end
  end

  describe "causality" do
    test "every finished is preceded by a started" do
      check_trace(
        fn ->
          Worker.do_work(5)
          Worker.do_work(6)
        end,
        fn trace ->
          assert causality(
                   %{:"$kind" => :worker_started, input: i1},
                   %{:"$kind" => :worker_finished, input: i2},
                   i1 == i2,
                   trace
                 )
        end
      )
    end
  end

  describe "synchronisation" do
    test "block_until waits for an async event" do
      ref = make_ref()

      check_trace(
        fn ->
          Worker.ping_after(20, ref)
          assert {:ok, %{ref: ^ref}} = block_until(%{:"$kind" => :pong, ref: ^ref}, 1000)
        end,
        fn trace ->
          assert [%{ref: ^ref}] = of_kind(:pong, trace)
        end
      )
    end

    test "wait_async_action runs the action and waits for the event" do
      ref = make_ref()

      check_trace(
        fn ->
          {action_ret, event} =
            wait_async_action(
              fn -> Worker.ping_after(20, ref) end,
              %{:"$kind" => :pong, ref: ^ref},
              1000
            )

          assert action_ret == :scheduled
          assert {:ok, %{ref: ^ref}} = event
        end,
        fn _trace -> true end
      )
    end
  end

  describe "give_or_take" do
    test "passes within deviation" do
      assert give_or_take(100, 5, 103)
    end

    test "raises outside deviation" do
      assert_raise RuntimeError, ~r/give_or_take failed/, fn ->
        give_or_take(100, 5, 200)
      end
    end
  end
end
