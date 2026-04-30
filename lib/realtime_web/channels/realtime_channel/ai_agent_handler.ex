defmodule RealtimeWeb.RealtimeChannel.AiAgentHandler do
  @moduledoc """
  Handles the AI Agent feature from Realtime.
  """
  use Realtime.Logs

  import Phoenix.Socket, only: [assign: 3]
  import Phoenix.Channel, only: [push: 3]

  alias Extensions.AiAgent.Session
  alias Extensions.AiAgent.SessionSupervisor
  alias Phoenix.Socket
  alias Realtime.Api.Tenant
  alias Realtime.FeatureFlags
  alias Realtime.Messages
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.AiPolicies

  @spec notify_session_started(pid() | nil) :: :ok
  def notify_session_started(pid) when is_pid(pid), do: GenServer.cast(pid, :emit_session_started)
  def notify_session_started(_), do: :ok

  @ai_events ["agent_input", "agent_cancel"]

  @spec ai_event?(map() | tuple()) :: boolean()
  def ai_event?(%{"event" => event}) when event in @ai_events, do: true
  def ai_event?({event, _, _, _}) when event in @ai_events, do: true
  def ai_event?(_), do: false

  @spec handle(map() | tuple(), pid() | nil, Socket.t()) :: {:noreply, Socket.t()}
  def handle(%{"event" => event} = payload, db_conn, %{assigns: %{ai_session: pid}} = socket)
      when event in @ai_events and is_pid(pid) do
    do_handle_ai_event(event, payload, db_conn, socket)
  end

  def handle({event, :json, payload_binary, _metadata}, db_conn, %{assigns: %{ai_session: pid}} = socket)
      when event in @ai_events and is_pid(pid) do
    payload = %{"event" => event, "payload" => Phoenix.json_library().decode!(payload_binary)}
    do_handle_ai_event(event, payload, db_conn, socket)
  end

  def handle(_payload, _db_conn, socket), do: {:noreply, socket}

  @dialyzer {:nowarn_function, start_session: 6}
  @spec start_session(map(), Tenant.t(), String.t(), String.t(), pid(), boolean()) ::
          {:ok, pid() | nil} | {:error, term()}
  def start_session(%{"enabled" => true}, _tenant, _tenant_topic, _tenant_id, _channel_pid, false) do
    {:error, :ai_requires_private_channel}
  end

  def start_session(
        %{"enabled" => true, "agent" => agent_name} = ai_config,
        %{ai_enabled: true} = tenant,
        tenant_topic,
        tenant_id,
        channel_pid,
        true
      )
      when is_binary(agent_name) do
    with true <- FeatureFlags.enabled?("ai_agent", tenant_id),
         extension when not is_nil(extension) <-
           Enum.find(tenant.extensions, &(&1.type == "ai_agent" and &1.name == agent_name)) do
      session_id = if is_binary(ai_config["session_id"]), do: ai_config["session_id"]

      opts = [
        tenant_id: tenant_id,
        tenant_topic: tenant_topic,
        settings: extension.settings,
        channel_pid: channel_pid,
        session_id: session_id,
        max_ai_events_per_second: tenant.max_ai_events_per_second,
        max_ai_tokens_per_minute: tenant.max_ai_tokens_per_minute
      ]

      do_start_session(opts, tenant_id, agent_name)
    else
      false ->
        Logger.error("AiAgentFeatureFlagDisabled agent=#{agent_name} tenant=#{tenant_id}")
        {:error, :ai_agent_feature_disabled}

      nil ->
        Logger.error("AiAgentNotFound agent=#{agent_name} tenant=#{tenant_id}")
        {:error, :no_ai_agent_configured}
    end
  end

  def start_session(
        %{"enabled" => true, "agent" => agent_name},
        _tenant,
        _tenant_topic,
        tenant_id,
        _channel_pid,
        _private?
      )
      when is_binary(agent_name) do
    Logger.error("AiNotEnabledForTenant agent=#{agent_name} tenant=#{tenant_id}")
    {:error, :no_ai_agent_configured}
  end

  def start_session(_ai_config, _tenant, _tenant_topic, _tenant_id, _channel_pid, _private?), do: {:ok, nil}

  @spec replay(map(), String.t(), pid(), String.t(), boolean()) :: {:ok, MapSet.t()} | {:error, term()}
  def replay(%{"ai" => %{"replay" => _}}, _topic, _conn, _tid, false), do: {:error, :invalid_replay_channel}

  def replay(%{"ai" => %{"replay" => params}}, topic, conn, tid, true) when is_map(params) do
    with {:ok, messages, message_ids} <-
           Messages.replay(conn, tid, topic, params["since"], params["limit"] || 25, [:ai_agent_event]) do
      send(self(), {:replay, messages})
      {:ok, message_ids}
    end
  end

  def replay(_config, _topic, _conn, _tid, _private?), do: {:ok, MapSet.new()}

  defp do_handle_ai_event(event, payload, db_conn, socket) do
    %{authorization_context: authorization_context, policies: policies, ai_session: pid} = socket.assigns

    case check_ai_authorization(policies || %Policies{}, db_conn, authorization_context) do
      {:ok, %Policies{ai_agent: %AiPolicies{write: true}} = policies} ->
        socket = assign(socket, :policies, policies)
        route_ai_event(event, payload["payload"] || %{}, pid)
        {:noreply, socket}

      {:ok, _policies} ->
        push(socket, "ai_event", %{"event" => "agent_error", "payload" => %{"reason" => "unauthorized"}})
        {:noreply, socket}

      {:error, :rls_policy_error, error} ->
        log_error("RlsPolicyError", error)
        push(socket, "ai_event", %{"event" => "agent_error", "payload" => %{"reason" => "unauthorized"}})
        {:noreply, socket}

      {:error, error} ->
        log_error("UnableToSetPolicies", error)
        {:noreply, socket}
    end
  end

  defp check_ai_authorization(%Policies{ai_agent: %AiPolicies{write: nil}} = policies, db_conn, ctx) do
    Authorization.get_write_authorizations(policies, db_conn, ctx, ai_enabled?: true)
  end

  defp check_ai_authorization(policies, _db_conn, _ctx), do: {:ok, policies}

  defp route_ai_event("agent_input", payload, pid), do: Session.handle_input(pid, payload)
  defp route_ai_event("agent_cancel", _payload, pid), do: Session.cancel(pid)

  defp do_start_session(opts, tenant_id, agent_name) do
    case SessionSupervisor.start_session(opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error("AiSessionStartFailed reason=#{inspect(reason)} tenant=#{tenant_id} agent=#{agent_name}")
        {:error, :ai_session_start_failed}
    end
  catch
    :exit, reason ->
      Logger.error("AiSessionStartFailed reason=#{inspect(reason)} tenant=#{tenant_id} agent=#{agent_name}")
      {:error, :ai_session_start_failed}
  end
end
