defmodule Extensions.AiAgent.SessionPersistenceTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Extensions.AiAgent.Session
  alias Realtime.Api.Message
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Repo

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
    Mimic.allow(Connect, self(), pid)
    Mimic.allow(Repo, self(), pid)
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

  describe "session_id in session_started event" do
    test "broadcasts a fresh UUID when no client session_id provided" do
      start_session()

      assert_receive %Phoenix.Socket.Broadcast{
                       event: "agent_session_started",
                       payload: %{session_id: <<_::binary-size(36)>>}
                     },
                     500
    end

    test "uses and broadcasts the client-provided session_id" do
      client_id = UUID.uuid4()
      stub(Connect, :lookup_or_start_connection, fn _ -> {:error, :not_found} end)

      start_session(session_id: client_id)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started", payload: %{session_id: ^client_id}}, 500
    end
  end

  describe "persist_async: user messages" do
    test "persists user message to tenant DB on text input" do
      test_pid = self()

      stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, :fake_conn} end)

      stub(Repo, :insert_all_entries, fn _conn, changesets, _struct ->
        messages = Enum.map(changesets, & &1.changes)
        send(test_pid, {:persisted, messages})
        {:ok, []}
      end)

      pid = start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500
      Mimic.allow(Connect, self(), pid)
      Mimic.allow(Repo, self(), pid)

      Session.handle_input(pid, %{"text" => "Hello agent"})

      assert_receive {:persisted,
                      [
                        %{
                          extension: :ai_agent,
                          payload: %{"role" => "user", "content" => "Hello agent", "session_id" => session_id}
                        },
                        %{
                          extension: :ai_agent_event,
                          event: "agent_input",
                          payload: %{"text" => "Hello agent"}
                        }
                      ]},
                     500

      assert is_binary(session_id)
    end

    test "persists tool_result message to tenant DB" do
      test_pid = self()

      stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, :fake_conn} end)

      stub(Repo, :insert_all_entries, fn _conn, changesets, _struct ->
        messages = Enum.map(changesets, & &1.changes)
        send(test_pid, {:persisted, messages})
        {:ok, []}
      end)

      pid = start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500
      Mimic.allow(Connect, self(), pid)
      Mimic.allow(Repo, self(), pid)

      Session.handle_input(pid, %{"tool_result" => %{"tool_call_id" => "call_1", "content" => "42 degrees"}})

      assert_receive {:persisted, [%{payload: %{"role" => "tool", "content" => "42 degrees"}}]}, 500
    end
  end

  describe "persist_async: assistant messages" do
    test "accumulates text deltas and persists full assistant message on done" do
      test_pid = self()

      stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, :fake_conn} end)

      stub(Repo, :insert_all_entries, fn _conn, changesets, _struct ->
        messages = Enum.map(changesets, & &1.changes)
        send(test_pid, {:persisted, messages})
        {:ok, []}
      end)

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        acc = callback.({:status, 200}, acc)
        acc = callback.({:data, sse_text("Hello") <> sse_text(" world") <> sse_done()}, acc)
        {:ok, acc}
      end)

      pid = start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500
      Mimic.allow(Connect, self(), pid)
      Mimic.allow(Repo, self(), pid)

      Session.handle_input(pid, %{"text" => "Say hi"})

      assert_receive {:persisted, [%{payload: %{"role" => "user"}}, %{extension: :ai_agent_event}]}, 500

      assert_receive {:persisted,
                      [%{payload: %{"role" => "assistant", "content" => "Hello world"}}, %{extension: :ai_agent_event}]},
                     1000
    end

    test "does not persist assistant message when stream is empty (tool-call only turn)" do
      test_pid = self()

      stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, :fake_conn} end)

      stub(Repo, :insert_all_entries, fn _conn, changesets, _struct ->
        messages = Enum.map(changesets, & &1.changes)
        send(test_pid, {:persisted, messages})
        {:ok, []}
      end)

      stub(Finch, :stream, fn _req, _name, acc, callback, _opts ->
        finish = Jason.encode!(%{"choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]})
        acc = callback.({:status, 200}, acc)
        acc = callback.({:data, "data: #{finish}\n\ndata: [DONE]\n\n"}, acc)
        {:ok, acc}
      end)

      pid = start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500
      Mimic.allow(Connect, self(), pid)
      Mimic.allow(Repo, self(), pid)

      Session.handle_input(pid, %{"text" => "Run a tool"})

      assert_receive {:persisted, [%{payload: %{"role" => "user"}}, %{extension: :ai_agent_event}]}, 500
      refute_receive {:persisted, [%{payload: %{"role" => "assistant", "content" => _}} | _]}, 200
    end
  end

  describe "load_history: resuming a session" do
    test "loads prior messages when client session_id is provided" do
      client_id = UUID.uuid4()

      prior_message = %Message{
        topic: "test-tenant:private:agent:some-topic",
        extension: :ai_agent,
        payload: %{"role" => "user", "content" => "Prior question", "session_id" => client_id},
        inserted_at: NaiveDateTime.utc_now()
      }

      stub(Connect, :lookup_or_start_connection, fn _ -> {:ok, :fake_conn} end)
      stub(Repo, :all, fn _conn, _query, Message -> {:ok, [prior_message]} end)

      pid = start_session(session_id: client_id)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started", payload: %{session_id: ^client_id}}, 500

      test_pid = self()

      stub(Finch, :stream, fn _req, _name, acc, _callback, _opts ->
        send(test_pid, :stream_called)
        {:ok, acc}
      end)

      Mimic.allow(Finch, self(), pid)
      Session.handle_input(pid, %{"text" => "Follow-up"})
      assert_receive :stream_called, 500
    end

    test "starts fresh when no client session_id (does not query DB)" do
      reject(&Repo.all/3)
      start_session()
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started"}, 500
    end

    test "starts fresh gracefully when DB connection is unavailable" do
      client_id = UUID.uuid4()
      stub(Connect, :lookup_or_start_connection, fn _ -> {:error, :unavailable} end)

      start_session(session_id: client_id)
      assert_receive %Phoenix.Socket.Broadcast{event: "agent_session_started", payload: %{session_id: ^client_id}}, 500
    end
  end
end
