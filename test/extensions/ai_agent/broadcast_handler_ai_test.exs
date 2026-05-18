defmodule Extensions.AiAgent.BroadcastHandlerAiTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Extensions.AiAgent.Session
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.AiPolicies
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.RealtimeChannel.AiAgentHandler

  defp private_socket_with_ai_session(pid) do
    %Phoenix.Socket{
      joined: true,
      topic: "realtime:test",
      transport_pid: self(),
      serializer: Phoenix.Socket.V1.JSONSerializer,
      join_ref: "1",
      assigns: %{
        ai_session: pid,
        private?: true,
        tenant: "tenant-id",
        tenant_topic: "tenant:topic",
        self_broadcast: true,
        ack_broadcast: false,
        authorization_context: %Authorization{tenant_id: "tenant-id", topic: "topic"},
        policies: nil
      }
    }
  end

  describe "handle/2 with AI events on private channel" do
    setup do
      stub(Connect, :lookup_or_start_connection, fn _id -> {:ok, self()} end)
      :ok
    end

    test "routes agent_input when ai_agent write policy is granted" do
      test_pid = self()
      session_pid = spawn(fn -> Process.sleep(:infinity) end)

      stub(Authorization, :get_write_authorizations, fn _policies, _conn, _ctx, _opts ->
        {:ok, %Policies{ai_agent: %AiPolicies{write: true}}}
      end)

      stub(Session, :handle_input, fn _pid, input ->
        send(test_pid, {:routed_input, input})
        :ok
      end)

      payload = %{"event" => "agent_input", "payload" => %{"text" => "hello"}}
      {:noreply, _} = AiAgentHandler.handle(payload, :fake_conn, private_socket_with_ai_session(session_pid))

      assert_receive {:routed_input, %{"text" => "hello"}}
    end

    test "does not route agent_input when ai_agent write policy is denied" do
      session_pid = spawn(fn -> Process.sleep(:infinity) end)

      stub(Authorization, :get_write_authorizations, fn _policies, _conn, _ctx, _opts ->
        {:ok, %Policies{ai_agent: %AiPolicies{write: false}}}
      end)

      reject(&Session.handle_input/2)

      payload = %{"event" => "agent_input", "payload" => %{"text" => "hello"}}
      {:noreply, _} = AiAgentHandler.handle(payload, :fake_conn, private_socket_with_ai_session(session_pid))
    end

    test "routes agent_cancel when ai_agent write policy is granted" do
      test_pid = self()
      session_pid = spawn(fn -> Process.sleep(:infinity) end)

      stub(Authorization, :get_write_authorizations, fn _policies, _conn, _ctx, _opts ->
        {:ok, %Policies{ai_agent: %AiPolicies{write: true}}}
      end)

      stub(Session, :cancel, fn _pid ->
        send(test_pid, :cancelled)
        :ok
      end)

      payload = %{"event" => "agent_cancel", "payload" => %{}}
      {:noreply, _} = AiAgentHandler.handle(payload, :fake_conn, private_socket_with_ai_session(session_pid))

      assert_receive :cancelled
    end
  end

  describe "handle/3 with binary-encoded AI events (V2 kind=3) on private channel" do
    setup do
      stub(Connect, :lookup_or_start_connection, fn _id -> {:ok, self()} end)
      :ok
    end

    test "routes agent_input from binary tuple when ai_agent write policy is granted" do
      test_pid = self()
      session_pid = spawn(fn -> Process.sleep(:infinity) end)

      stub(Authorization, :get_write_authorizations, fn _policies, _conn, _ctx, _opts ->
        {:ok, %Policies{ai_agent: %AiPolicies{write: true}}}
      end)

      stub(Session, :handle_input, fn _pid, input ->
        send(test_pid, {:routed_input, input})
        :ok
      end)

      payload = {"agent_input", :json, Jason.encode!(%{"text" => "hello"}), %{}}
      {:noreply, _} = AiAgentHandler.handle(payload, :fake_conn, private_socket_with_ai_session(session_pid))

      assert_receive {:routed_input, %{"text" => "hello"}}
    end

    test "does not route agent_input from binary tuple when ai_agent write policy is denied" do
      session_pid = spawn(fn -> Process.sleep(:infinity) end)

      stub(Authorization, :get_write_authorizations, fn _policies, _conn, _ctx, _opts ->
        {:ok, %Policies{ai_agent: %AiPolicies{write: false}}}
      end)

      reject(&Session.handle_input/2)

      payload = {"agent_input", :json, Jason.encode!(%{"text" => "hello"}), %{}}
      {:noreply, _} = AiAgentHandler.handle(payload, :fake_conn, private_socket_with_ai_session(session_pid))
    end

    test "routes agent_cancel from binary tuple when ai_agent write policy is granted" do
      test_pid = self()
      session_pid = spawn(fn -> Process.sleep(:infinity) end)

      stub(Authorization, :get_write_authorizations, fn _policies, _conn, _ctx, _opts ->
        {:ok, %Policies{ai_agent: %AiPolicies{write: true}}}
      end)

      stub(Session, :cancel, fn _pid ->
        send(test_pid, :cancelled)
        :ok
      end)

      payload = {"agent_cancel", :json, Jason.encode!(%{}), %{}}
      {:noreply, _} = AiAgentHandler.handle(payload, :fake_conn, private_socket_with_ai_session(session_pid))

      assert_receive :cancelled
    end
  end
end
