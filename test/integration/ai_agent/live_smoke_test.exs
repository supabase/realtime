defmodule Realtime.Integration.AiAgent.LiveSmokeTest do
  @moduledoc """
  End-to-end integration tests for the AI agent extension using a real Ollama
  instance. These tests require Ollama to be running and a model to be available.

  Run with:
      mix test --include live_llm

  Or set OLLAMA_HOST and OLLAMA_MODEL env vars to use an external instance:
      OLLAMA_HOST=http://my-ollama:11434 OLLAMA_MODEL=llama3.2:1b mix test --include live_llm
  """

  use RealtimeWeb.ConnCase, async: false

  import Generators
  import Integrations

  alias Phoenix.Socket.Message
  alias Realtime.Database
  alias Realtime.Integration.WebsocketClient

  @moduletag :live_llm
  @moduletag :capture_log
  @moduletag timeout: 120_000

  @agent_name "smoke-agent"
  @agent_topic "agent:smoke:test"
  @serializer Phoenix.Socket.V1.JSONSerializer

  setup_all do
    case Ollama.ensure_ready() do
      :ok ->
        :ok

      {:error, reason} ->
        raise "Ollama not available for :live_llm tests: #{reason}\n" <>
                "Set OLLAMA_HOST env var or ensure Docker is running.\n" <>
                "Skipping with `mix test` (no --include live_llm) is fine."
    end
  end

  setup do
    %{tenant: base_tenant} = checkout_tenant_and_connect()
    tenant = add_ai_agent_extension(base_tenant, @agent_name)

    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
    clean_table(db_conn, "realtime", "messages")
    create_rls_policies(db_conn, [:authenticated_all_topic_read, :authenticated_all_topic_insert], %{})

    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(db_conn), do: GenServer.stop(db_conn, :normal, 1_000)
    end)

    %{tenant: tenant}
  end

  describe "AI agent via WebSocket" do
    test "receives streaming text response for a simple prompt", %{tenant: tenant} do
      {socket, _} = get_connection(tenant, @serializer, role: "authenticated")
      topic = "realtime:#{@agent_topic}"
      config = %{private: true, broadcast: %{self: true}, ai: %{enabled: true, agent: @agent_name}}

      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5_000

      assert_receive %Message{
                       event: "ai_event",
                       payload: %{"event" => "agent_session_started", "payload" => %{"session_id" => session_id}}
                     },
                     5_000

      assert is_binary(session_id)

      WebsocketClient.send_event(socket, topic, "broadcast", %{
        "event" => "agent_input",
        "type" => "broadcast",
        "payload" => %{"text" => "Reply with exactly the word: pong"}
      })

      {text, stop_reason} = collect_response(topic, 30_000)

      assert is_binary(text) and byte_size(text) > 0,
             "Expected non-empty text response, got: #{inspect(text)}"

      assert stop_reason in ["stop", "end_turn", "length"],
             "Unexpected stop reason: #{inspect(stop_reason)}"
    end

    test "session_id is preserved on reconnect", %{tenant: tenant} do
      topic = "realtime:#{@agent_topic}"
      config = %{private: true, broadcast: %{self: true}, ai: %{enabled: true, agent: @agent_name}}

      {socket, _} = get_connection(tenant, @serializer, role: "authenticated")
      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5_000

      assert_receive %Message{
                       event: "ai_event",
                       payload: %{"event" => "agent_session_started", "payload" => %{"session_id" => session_id}}
                     },
                     5_000

      WebsocketClient.send_event(socket, topic, "broadcast", %{
        "event" => "agent_input",
        "type" => "broadcast",
        "payload" => %{"text" => "Remember the number 42. Just say 'OK'."}
      })

      {_text, _} = collect_response(topic, 30_000)
      WebsocketClient.close(socket)

      {socket2, _} = get_connection(tenant, @serializer, role: "authenticated")

      config2 = %{
        private: true,
        broadcast: %{self: true},
        ai: %{enabled: true, agent: @agent_name, session_id: session_id}
      }

      WebsocketClient.join(socket2, topic, %{config: config2})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5_000

      assert_receive %Message{
                       event: "ai_event",
                       payload: %{"event" => "agent_session_started", "payload" => %{"session_id" => ^session_id}}
                     },
                     5_000

      WebsocketClient.send_event(socket2, topic, "broadcast", %{
        "event" => "agent_input",
        "type" => "broadcast",
        "payload" => %{"text" => "What number did I ask you to remember?"}
      })

      {text2, _} = collect_response(topic, 30_000)
      assert is_binary(text2) and byte_size(text2) > 0
    end

    test "cancels an in-flight response", %{tenant: tenant} do
      {socket, _} = get_connection(tenant, @serializer, role: "authenticated")
      topic = "realtime:#{@agent_topic}"
      config = %{private: true, broadcast: %{self: true}, ai: %{enabled: true, agent: @agent_name}}

      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5_000
      assert_receive %Message{event: "ai_event", payload: %{"event" => "agent_session_started"}}, 5_000

      WebsocketClient.send_event(socket, topic, "broadcast", %{
        "event" => "agent_input",
        "type" => "broadcast",
        "payload" => %{"text" => "Count from 1 to 1000 slowly."}
      })

      assert_receive %Message{event: "ai_event", payload: %{"event" => "agent_text_delta"}}, 15_000

      WebsocketClient.send_event(socket, topic, "broadcast", %{
        "event" => "agent_cancel",
        "type" => "broadcast",
        "payload" => %{}
      })

      refute_receive %Message{event: "ai_event", payload: %{"event" => "agent_done"}}, 1_000
    end

    test "returns error event on invalid model", %{tenant: tenant} do
      bad_tenant = add_ai_agent_extension(tenant, "broken-agent", %{model: "nonexistent-model-xyz"})

      {socket, _} = get_connection(bad_tenant, @serializer, role: "authenticated")
      topic = "realtime:#{@agent_topic}"
      config = %{private: true, broadcast: %{self: true}, ai: %{enabled: true, agent: "broken-agent"}}

      WebsocketClient.join(socket, topic, %{config: config})
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5_000
      assert_receive %Message{event: "ai_event", payload: %{"event" => "agent_session_started"}}, 5_000

      WebsocketClient.send_event(socket, topic, "broadcast", %{
        "event" => "agent_input",
        "type" => "broadcast",
        "payload" => %{"text" => "Hello"}
      })

      assert_receive %Message{event: "ai_event", payload: %{"event" => "agent_error"}}, 15_000
    end
  end

  defp collect_response(topic, timeout), do: collect_response(topic, timeout, "", nil)

  defp collect_response(topic, timeout, text_acc, _stop_reason) do
    receive do
      %Message{
        event: "ai_event",
        payload: %{"event" => "agent_text_delta", "payload" => %{"delta" => delta}},
        topic: ^topic
      } ->
        collect_response(topic, timeout, text_acc <> delta, nil)

      %Message{
        event: "ai_event",
        payload: %{"event" => "agent_done", "payload" => %{"stop_reason" => reason}},
        topic: ^topic
      } ->
        {text_acc, reason}

      %Message{event: "ai_event", payload: %{"event" => "agent_error", "payload" => %{"reason" => reason}}} ->
        raise "Agent returned error: #{inspect(reason)}"
    after
      timeout ->
        raise "Timed out after #{timeout}ms. Collected so far: #{inspect(text_acc)}"
    end
  end
end
