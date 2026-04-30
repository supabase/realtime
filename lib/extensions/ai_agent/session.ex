defmodule Extensions.AiAgent.Session do
  @moduledoc """
  GenServer that manages one AI conversation session per channel join.

  Lifecycle:
  - Started by `Extensions.AiAgent.SessionSupervisor` when a channel joins
    with `config.ai.enabled = true`.
  - Receives `agent_input` and `agent_cancel` from the channel process.
  - Runs the adapter in a `Task.Supervisor.async_nolink` task so an adapter
    crash broadcasts an error event rather than crashing the session.
  - Broadcasts `Extensions.AiAgent.Event` structs to the channel's PubSub
    topic as `:ai_events`.
  - Persists conversation turns to `realtime.messages` (extension: ai_agent)
    in the tenant's own database.  Pass `session_id` in `config.ai` to
    continue a prior session; omit to start fresh.
  - Terminates when the channel process terminates.
  """

  use GenServer
  use Realtime.Logs

  import Ecto.Query, only: [from: 2]

  alias Extensions.AiAgent.Adapter.AnthropicMessages
  alias Extensions.AiAgent.Adapter.ChatCompletions
  alias Extensions.AiAgent.Types.Event
  alias Realtime.Api.Message
  alias Realtime.Crypto
  alias Realtime.GenCounter
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Repo
  alias RealtimeWeb.RealtimeChannel.MessageDispatcher
  alias RealtimeWeb.TenantBroadcaster

  @enforce_keys [
    :tenant_id,
    :tenant_topic,
    :session_id,
    :channel_pid,
    :settings,
    :adapter,
    :messages,
    :channel_ref,
    :events_rate_counter
  ]

  defstruct [
    :tenant_id,
    :tenant_topic,
    :session_id,
    :channel_pid,
    :settings,
    :adapter,
    :messages,
    :stream_task,
    :channel_ref,
    :events_rate_counter,
    assistant_buffer: [],
    token_usage: 0,
    max_ai_tokens_per_minute: 0
  ]

  @type t :: %__MODULE__{
          tenant_id: String.t(),
          tenant_topic: String.t(),
          session_id: String.t(),
          channel_pid: pid(),
          settings: map(),
          adapter: module(),
          messages: list(map()),
          stream_task: Task.t() | nil,
          channel_ref: reference(),
          events_rate_counter: RateCounter.Args.t(),
          assistant_buffer: iodata(),
          token_usage: non_neg_integer(),
          max_ai_tokens_per_minute: non_neg_integer()
        }

  @task_supervisor Extensions.AiAgent.TaskSupervisor
  @shutdown_grace_ms 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec handle_input(pid(), map()) :: :ok
  def handle_input(pid, input), do: GenServer.cast(pid, {:input, input})

  @spec cancel(pid()) :: :ok
  def cancel(pid), do: GenServer.cast(pid, :cancel)

  @max_heap_words 200_000

  @impl true
  def init(opts) do
    Process.flag(:max_heap_size, @max_heap_words)

    tenant_id = Keyword.fetch!(opts, :tenant_id)
    tenant_topic = Keyword.fetch!(opts, :tenant_topic)
    raw_settings = Keyword.fetch!(opts, :settings)
    channel_pid = Keyword.fetch!(opts, :channel_pid)
    client_session_id = Keyword.get(opts, :session_id)
    max_ai_events_per_second = Keyword.get(opts, :max_ai_events_per_second, 100)
    max_ai_tokens_per_minute = Keyword.get(opts, :max_ai_tokens_per_minute, 60_000)
    system_prompt = raw_settings["system_prompt"]

    settings =
      Map.update(raw_settings, "api_key", nil, fn
        nil -> nil
        key -> Crypto.decrypt!(key)
      end)

    with {:ok, adapter} <- resolve_adapter(settings) do
      session_id = client_session_id || UUID.uuid4()
      ref = Process.monitor(channel_pid)

      events_rate_counter = Tenants.ai_events_per_second_rate(tenant_id, max_ai_events_per_second)
      RateCounter.new(events_rate_counter)

      Process.send_after(self(), :reset_token_window, :timer.minutes(1))

      state = %__MODULE__{
        tenant_id: tenant_id,
        tenant_topic: tenant_topic,
        session_id: session_id,
        channel_pid: channel_pid,
        settings: settings,
        adapter: adapter,
        messages: system_messages(system_prompt),
        channel_ref: ref,
        events_rate_counter: events_rate_counter,
        max_ai_tokens_per_minute: max_ai_tokens_per_minute
      }

      {:ok, state, initial_continue(client_session_id)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp system_messages(prompt) when is_binary(prompt) and prompt != "", do: [%{"role" => "system", "content" => prompt}]
  defp system_messages(_), do: []

  defp initial_continue(nil), do: {:continue, :session_started}
  defp initial_continue(_session_id), do: {:continue, :load_history}

  @impl true
  def handle_continue(:load_history, state) do
    prior = load_history(state.tenant_id, state.tenant_topic, state.session_id)
    state = %{state | messages: state.messages ++ prior}
    notify_session_started(state)
    {:noreply, state}
  end

  def handle_continue(:session_started, state) do
    notify_session_started(state)
    {:noreply, state}
  end

  @max_input_bytes 64_000

  @impl true
  def handle_cast({:input, _} = msg, state) do
    case check_rate_limits(state) do
      :ok ->
        dispatch_input(msg, state)

      {:error, reason} ->
        broadcast_event(state, %Event{type: :error, payload: %{reason: reason}})
        {:noreply, state}
    end
  end

  def handle_cast(:cancel, state) do
    {:noreply, cancel_stream(state)}
  end

  def handle_cast(msg, state) do
    log_warning("UnhandledCast", inspect(msg, limit: 3, printable_limit: 80))
    {:noreply, state}
  end

  @impl true
  def handle_info({:ai_event, %Event{type: :text_delta} = event}, state) do
    %Event{payload: %{delta: delta}} = event
    broadcast_event(state, event)
    {:noreply, %{state | assistant_buffer: [delta | state.assistant_buffer]}}
  end

  def handle_info({:ai_event, %Event{type: :done} = event}, state) do
    maybe_persist_assistant_turn(state)
    broadcast_event(state, event)
    {:noreply, %{state | stream_task: nil, assistant_buffer: []}}
  end

  def handle_info({:ai_event, %Event{type: :error} = event}, state) do
    broadcast_event(state, event)
    {:noreply, %{state | stream_task: nil, assistant_buffer: []}}
  end

  def handle_info({:ai_event, %Event{type: :tool_call_done} = event}, state) do
    tool_call = event.payload

    assistant_tool_call = %{
      "role" => "assistant",
      "tool_calls" => [
        %{
          "id" => tool_call.tool_call_id,
          "type" => "function",
          "function" => %{"name" => tool_call.name, "arguments" => tool_call.arguments}
        }
      ]
    }

    persist_messages(state, [assistant_tool_call])
    broadcast_event(state, event)
    {:noreply, %{state | messages: state.messages ++ [assistant_tool_call]}}
  end

  def handle_info({:ai_event, %Event{type: :usage} = event}, state) do
    %Event{payload: payload} = event
    tokens = Map.get(payload, :input_tokens, 0) + Map.get(payload, :output_tokens, 0)
    broadcast_event(state, event)
    {:noreply, %{state | token_usage: state.token_usage + tokens}}
  end

  def handle_info(:reset_token_window, state) do
    Process.send_after(self(), :reset_token_window, :timer.minutes(1))
    {:noreply, %{state | token_usage: 0}}
  end

  def handle_info({:ai_event, %Event{} = event}, state) do
    broadcast_event(state, event)
    {:noreply, state}
  end

  def handle_info({ref, result}, %{stream_task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:error, reason} ->
        log_error("AiStreamError", reason)
        broadcast_event(state, %Event{type: :error, payload: %{reason: "stream_failed"}})

      _ ->
        :ok
    end

    {:noreply, %{state | stream_task: nil, assistant_buffer: []}}
  end

  def handle_info({ref, _result}, %{stream_task: nil} = state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{stream_task: %Task{ref: ref}} = state) do
    log_error("AiStreamCrash", reason)
    broadcast_event(state, %Event{type: :error, payload: %{reason: "stream_failed"}})
    {:noreply, %{state | stream_task: nil, assistant_buffer: []}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{channel_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    log_warning("UnhandledInfo", inspect(msg, limit: 3, printable_limit: 80))
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cancel_stream(state)
    :ok
  end

  defp start_stream(state) do
    state = cancel_stream(state)
    caller = self()
    adapter = state.adapter
    settings = state.settings
    messages = state.messages

    task =
      Task.Supervisor.async_nolink(@task_supervisor, fn ->
        adapter.stream(settings, messages, caller)
      end)

    %{state | stream_task: task}
  end

  defp cancel_stream(%{stream_task: nil} = state), do: state

  defp cancel_stream(%{stream_task: task} = state) do
    Task.shutdown(task, @shutdown_grace_ms)
    %{state | stream_task: nil, assistant_buffer: []}
  end

  defp resolve_adapter(%{"protocol" => "openai_compatible", "base_url" => url}) when is_binary(url) and url != "",
    do: {:ok, ChatCompletions}

  defp resolve_adapter(%{"protocol" => "anthropic", "base_url" => url}) when is_binary(url) and url != "",
    do: {:ok, AnthropicMessages}

  defp resolve_adapter(%{"protocol" => protocol, "base_url" => url}) when is_binary(url) and url != "",
    do: {:error, "unknown protocol: #{protocol}"}

  defp resolve_adapter(%{"protocol" => _}), do: {:error, "missing base_url in settings"}
  defp resolve_adapter(_), do: {:error, "missing protocol in settings"}

  defp check_rate_limits(state) do
    GenCounter.add(state.events_rate_counter.id)

    case RateCounter.get(state.events_rate_counter) do
      {:ok, %{limit: %{triggered: true}}} -> {:error, "rate_limit_exceeded"}
      _ -> check_token_rate(state)
    end
  end

  defp check_token_rate(%{max_ai_tokens_per_minute: max, token_usage: usage}) when max > 0 and usage >= max do
    {:error, "token_limit_exceeded"}
  end

  defp check_token_rate(_state), do: :ok

  defp dispatch_input({:input, %{"text" => text}}, state) when is_binary(text) do
    stream_with_message(%{"role" => "user", "content" => text}, text, state)
  end

  defp dispatch_input(
         {:input, %{"tool_result" => %{"tool_call_id" => id, "content" => content}}},
         state
       )
       when is_binary(id) and is_binary(content) do
    stream_with_message(%{"role" => "tool", "tool_call_id" => id, "content" => content}, content, state)
  end

  defp dispatch_input(_msg, state), do: {:noreply, state}

  defp stream_with_message(_msg, body, state) when byte_size(body) > @max_input_bytes do
    broadcast_event(state, %Event{type: :error, payload: %{reason: "input_too_large"}})
    {:noreply, state}
  end

  defp stream_with_message(%{"role" => "user"} = msg, _body, state) do
    %{"content" => text} = msg
    persist_turn(state, msg, "agent_input", %{"text" => text})
    {:noreply, start_stream(%{state | messages: state.messages ++ [msg]})}
  end

  defp stream_with_message(msg, _body, state) do
    persist_messages(state, [msg])
    {:noreply, start_stream(%{state | messages: state.messages ++ [msg]})}
  end

  defp maybe_persist_assistant_turn(%__MODULE__{assistant_buffer: []}), do: :ok

  defp maybe_persist_assistant_turn(%__MODULE__{} = state) do
    %__MODULE__{assistant_buffer: buffer} = state
    text = buffer |> Enum.reverse() |> IO.iodata_to_binary()
    persist_turn(state, %{"role" => "assistant", "content" => text}, "agent_done", %{"text" => text})
  end

  defp notify_session_started(%__MODULE__{} = state) do
    %__MODULE__{session_id: session_id} = state
    broadcast_event(state, %Event{type: :session_started, payload: %{session_id: session_id}})
  end

  defp broadcast_event(%__MODULE__{tenant_id: tenant_id, tenant_topic: topic}, %Event{} = event) do
    message = %Phoenix.Socket.Broadcast{
      topic: topic,
      event: Event.broadcast_event(event),
      payload: event.payload
    }

    TenantBroadcaster.pubsub_broadcast(tenant_id, topic, message, MessageDispatcher, :ai_events)
  end

  @history_limit 100

  defp load_history(tenant_id, topic, session_id) do
    query =
      from(m in Message,
        where: m.topic == ^topic,
        where: m.extension == :ai_agent,
        where: fragment("(?)->>'session_id' = ?", m.payload, ^session_id),
        order_by: [asc: m.inserted_at],
        limit: @history_limit
      )

    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant_id),
         {:ok, rows} <- Repo.all(db_conn, query, Message) do
      Enum.map(rows, &Map.drop(&1.payload, ["session_id"]))
    else
      error ->
        log_error("LoadHistoryError", error)
        []
    end
  rescue
    exception ->
      log_error("LoadHistoryError", exception)
      []
  end

  defp persist_messages(%__MODULE__{tenant_id: tid, tenant_topic: topic, session_id: sid}, messages) do
    changesets = Enum.map(messages, &llm_message_changeset(topic, sid, &1))
    persist(tid, changesets)
  end

  defp persist_turn(%__MODULE__{tenant_id: tid, tenant_topic: topic, session_id: sid}, llm_msg, event, event_payload) do
    persist(tid, [
      llm_message_changeset(topic, sid, llm_msg),
      Message.changeset(%Message{}, %{
        topic: topic,
        extension: :ai_agent_event,
        event: event,
        payload: event_payload,
        private: true
      })
    ])
  end

  defp llm_message_changeset(topic, sid, msg) do
    Message.changeset(%Message{}, %{
      topic: topic,
      extension: :ai_agent,
      payload: Map.put(msg, "session_id", sid),
      private: true
    })
  end

  defp persist(tenant_id, changesets) do
    with {:ok, db_conn} <- Connect.lookup_or_start_connection(tenant_id) do
      Repo.insert_all_entries(db_conn, changesets, Message)
    else
      error -> log_error("PersistFailed", error)
    end
  rescue
    exception -> log_error("PersistFailed", exception)
  end
end
