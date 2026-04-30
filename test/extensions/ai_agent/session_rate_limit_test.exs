defmodule Extensions.AiAgent.SessionRateLimitTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Extensions.AiAgent.Session

  @encrypted_key Realtime.Crypto.encrypt!("sk-test")

  @settings %{
    "protocol" => "openai_compatible",
    "base_url" => "https://api.openai.com/v1",
    "model" => "gpt-4o",
    "api_key" => @encrypted_key
  }

  defp start_session(overrides \\ []) do
    topic = "test-tenant:private:agent:" <> UUID.uuid4()
    Phoenix.PubSub.subscribe(Realtime.PubSub, topic)

    opts =
      Keyword.merge(
        [
          tenant_id: "test-tenant",
          tenant_topic: topic,
          settings: @settings,
          channel_pid: self(),
          max_ai_events_per_second: 100,
          max_ai_tokens_per_minute: 60_000
        ],
        overrides
      )

    pid = start_supervised!({Session, opts})
    Mimic.allow(Finch, self(), pid)
    Mimic.allow(Realtime.RateCounter, self(), pid)
    {pid, topic}
  end

  describe "max_ai_events_per_second" do
    test "allows inputs when rate counter is not triggered" do
      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts -> {:ok, acc} end)
      stub(Realtime.RateCounter, :get, fn _ -> {:ok, %Realtime.RateCounter{limit: %{triggered: false}}} end)

      {pid, _topic} = start_session(max_ai_events_per_second: 100)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      Session.handle_input(pid, %{"text" => "hello"})
      refute_receive %Phoenix.Socket.Broadcast{event: "agent_error", payload: %{reason: "rate_limit_exceeded"}}, 200
    end

    test "rejects inputs when rate counter limit is triggered" do
      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts -> {:ok, acc} end)
      stub(Realtime.RateCounter, :get, fn _ -> {:ok, %Realtime.RateCounter{limit: %{triggered: true}}} end)

      {pid, _topic} = start_session(max_ai_events_per_second: 1)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      Session.handle_input(pid, %{"text" => "over limit"})
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_error", payload: %{reason: "rate_limit_exceeded"}}, 500
    end
  end

  describe "max_ai_tokens_per_minute" do
    test "allows inputs when token budget is not exhausted" do
      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts -> {:ok, acc} end)
      {pid, _topic} = start_session(max_ai_tokens_per_minute: 10_000)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      Session.handle_input(pid, %{"text" => "hello"})
      refute_receive %Phoenix.Socket.Broadcast{event: "agent_error", payload: %{reason: "token_limit_exceeded"}}, 200
    end

    test "rejects input when token budget is exhausted" do
      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts -> {:ok, acc} end)
      {pid, _topic} = start_session(max_ai_tokens_per_minute: 5)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      usage_event = %Extensions.AiAgent.Types.Event{type: :usage, payload: %{input_tokens: 5, output_tokens: 5}}
      send(pid, {:ai_event, usage_event})
      Process.sleep(10)

      Session.handle_input(pid, %{"text" => "over budget"})
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_error", payload: %{reason: "token_limit_exceeded"}}, 500
    end

    test "resets token budget after one minute window" do
      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts -> {:ok, acc} end)
      {pid, _topic} = start_session(max_ai_tokens_per_minute: 5)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      usage_event = %Extensions.AiAgent.Types.Event{type: :usage, payload: %{input_tokens: 3, output_tokens: 3}}
      send(pid, {:ai_event, usage_event})
      Process.sleep(10)

      Session.handle_input(pid, %{"text" => "over budget"})
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_error", payload: %{reason: "token_limit_exceeded"}}, 500

      send(pid, :reset_token_window)
      Process.sleep(10)

      Session.handle_input(pid, %{"text" => "after reset"})
      refute_receive %Phoenix.Socket.Broadcast{event: "agent_error", payload: %{reason: "token_limit_exceeded"}}, 200
    end

    test "zero max_ai_tokens_per_minute disables token limit" do
      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts -> {:ok, acc} end)
      {pid, _topic} = start_session(max_ai_tokens_per_minute: 0)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      usage_event = %Extensions.AiAgent.Types.Event{type: :usage, payload: %{input_tokens: 9_999_999, output_tokens: 0}}
      send(pid, {:ai_event, usage_event})
      Process.sleep(10)

      Session.handle_input(pid, %{"text" => "should still work"})
      refute_receive %Phoenix.Socket.Broadcast{event: "agent_error", payload: %{reason: "token_limit_exceeded"}}, 200
    end
  end
end
