defmodule Extensions.AiAgent.SessionTest do
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
          channel_pid: self()
        ],
        overrides
      )

    pid = start_supervised!({Session, opts})
    Mimic.allow(Finch, self(), pid)
    pid
  end

  defp sse_text(text) do
    data = Jason.encode!(%{"choices" => [%{"delta" => %{"content" => text}, "finish_reason" => nil}]})
    "data: #{data}\n\n"
  end

  defp sse_done do
    data = Jason.encode!(%{"choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]})
    "data: #{data}\n\ndata: [DONE]\n\n"
  end

  describe "start_link/1" do
    test "starts successfully with valid settings" do
      pid = start_session()
      assert is_pid(pid)
      assert Process.alive?(pid)
    end

    test "emits session_started event on init" do
      start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500
    end
  end

  describe "handle_input/2 with text" do
    test "sends text_delta directly to channel and done via PubSub" do
      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        acc = callback.({:status, 200}, acc)
        acc = callback.({:data, sse_text("Hello") <> sse_done()}, acc)
        {:ok, acc}
      end)

      pid = start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      Session.handle_input(pid, %{"text" => "Say hello"})

      assert_receive %Phoenix.Socket.Broadcast{event: "agent_text_delta", payload: %{delta: "Hello"}}, 1000
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_done"}, 1000
    end

    test "rejects text larger than 64KB" do
      pid = start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      large_text = String.duplicate("a", 65_000)
      Session.handle_input(pid, %{"text" => large_text})

      assert_receive %Phoenix.Socket.Broadcast{event: "agent_error", payload: %{reason: "input_too_large"}}, 500
    end
  end

  describe "cancel/1" do
    test "cancels an in-flight stream" do
      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts ->
        Process.sleep(:infinity)
        {:ok, acc}
      end)

      pid = start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      Session.handle_input(pid, %{"text" => "This will be cancelled"})
      Session.cancel(pid)

      refute_receive %Phoenix.Socket.Broadcast{event: "agent_done"}, 200
    end
  end

  describe "adapter crash isolation" do
    test "broadcasts error event when adapter raises instead of crashing session" do
      stub(Finch, :stream, fn _req, _name, _acc, _callback, _opts ->
        raise "simulated provider crash"
      end)

      pid = start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      Session.handle_input(pid, %{"text" => "trigger crash"})

      assert_receive %Phoenix.Socket.Broadcast{event: "agent_error"}, 1000
      assert Process.alive?(pid)
    end
  end

  describe "channel process termination" do
    test "session stops when channel process dies" do
      channel_pid = spawn(fn -> Process.sleep(:infinity) end)
      pid = start_session(channel_pid: channel_pid)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500

      ref = Process.monitor(pid)
      Process.exit(channel_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1000
    end
  end
end
