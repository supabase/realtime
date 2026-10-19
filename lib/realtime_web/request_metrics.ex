defmodule RealtimeWeb.RequestMetrics do
  @moduledoc """
  Records one outcome per client request for the client request ingress SLI.

  Every request ends in exactly one of four outcomes:

    * `:success` - handled (good)
    * `:rejected` - refused because of the client's request: policy deny, payload too large (good)
    * `:internal_failure` - Realtime failed: a crash or an unexpected error (bad)
    * `:upstream_failure` - a dependency failed: tenant database, pool, auth (bad)
  """

  @type request :: :join | :broadcast | :presence | :access_token | :postgres_changes
  @type transport :: :ws | :http
  @type outcome :: :success | :rejected | :internal_failure | :upstream_failure

  @event [:realtime, :client_request]

  @doc """
  Returns the telemetry event name, [:realtime, :client_request].
  """
  def event, do: @event

  @doc """
  Stores `{outcome, reason}` under the `:request_outcome` assign.

  If one is already set, it is not overwritten. The first outcome wins, so an error branch that
  falls through cannot overwrite the real cause. Called from the error sites
  (`BroadcastHandler.maybe_reply_error/2`, the payload size paths).
  """
  @spec put_outcome(Phoenix.Socket.t(), outcome(), atom()) :: Phoenix.Socket.t()
  def put_outcome(socket, outcome, reason) do
    if is_nil(socket.assigns[:request_outcome]) do
      Phoenix.Socket.assign(socket, :request_outcome, {outcome, reason})
    else
      socket
    end
  end

  @doc """
  Runs `fun.()`, which must return a channel callback result, and emits exactly one event.

  If the returned socket has an outcome, that is emitted. If it has none, `{:success, :none}` is
  emitted.

  If `fun` raised, exited, or threw, `{:internal_failure, kind}` is emitted, where `kind` is `:error`,
  `:exit` or `:throw`. The exception is re-raised with `:erlang.raise/3` so the channel crashes
  exactly as it does today.

  Returns the result with `:request_outcome` removed from the socket, so it cannot leak into the
  next request on the same channel.
  """
  @spec track(request(), transport(), (-> result)) :: result when result: tuple()
  def track(request, transport, fun) do
    fun.()
  catch
    kind, reason ->
      record(request, transport, :internal_failure, kind)
      :erlang.raise(kind, reason, __STACKTRACE__)
  else
    {:noreply, socket} ->
      new_socket = record_and_cleanup(socket, request, transport)
      {:noreply, new_socket}

    {:reply, reply, socket} ->
      new_socket = record_and_cleanup(socket, request, transport)
      {:reply, reply, new_socket}

    {:stop, reason, socket} ->
      new_socket = record_and_cleanup(socket, request, transport)
      {:stop, reason, new_socket}

    {:stop, reason, reply, socket} ->
      new_socket = record_and_cleanup(socket, request, transport)
      {:stop, reason, reply, new_socket}
  end

  @doc """
  Records a successful request with the given request and transport.
  """
  @spec record(request(), transport(), :success) :: :ok
  def record(request, transport, :success) do
    record(request, transport, :success, :none)
  end

  @doc """
  Emits a telemetry event with the given request, transport, outcome, and reason.
  """
  @spec record(request(), transport(), outcome(), atom()) :: :ok
  def record(request, transport, outcome, reason) do
    :telemetry.execute(@event, %{count: 1}, %{
      request: request,
      transport: transport,
      outcome: outcome,
      reason: reason
    })
  end

  @doc """
  Maps a `BroadcastHandler` error code to an outcome.
  """
  @spec classify_broadcast_error(atom()) :: {outcome(), atom()}
  def classify_broadcast_error(code) do
    case code do
      :unauthorized -> {:rejected, code}
      :payload_size_exceeded -> {:rejected, code}
      :rls_policy_error -> {:upstream_failure, code}
      :query_canceled -> {:upstream_failure, code}
      :unable_to_connect_to_project -> {:upstream_failure, code}
      :database_lack_of_connections -> {:upstream_failure, code}
      :database_connection_rate_limit_reached -> {:upstream_failure, code}
      :initializing_project_connection -> {:upstream_failure, code}
      :increase_connection_pool -> {:upstream_failure, code}
      _ -> {:internal_failure, code}
    end
  end

  defp record_and_cleanup(socket, request, transport) do
    {outcome, reason} = socket.assigns[:request_outcome] || {:success, :none}
    record(request, transport, outcome, reason)
    %{socket | assigns: Map.delete(socket.assigns, :request_outcome)}
  end
end
