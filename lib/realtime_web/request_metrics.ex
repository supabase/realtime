defmodule RealtimeWeb.RequestMetrics do
  @moduledoc """
  Records one outcome per client request for the client request ingress SLI.

  Every request ends in exactly one of four outcomes:

    * `:success` - handled (good)
    * `:rejected` - refused because of the client's request: policy deny, payload too large (good)
    * `:internal_failure` - Realtime failed: a crash or an unexpected error (bad)
    * `:upstream_failure` - a dependency failed: tenant database or connection pool (bad)

  An outcome is a value, either `:success` or `{kind, reason}`. The code that handles a request
  returns its outcome next to its result, and `track/3` records it. Nothing is stored on the
  socket. A success has no reason of its own, so the reason `:none` appears only on a success.
  """

  @type request :: :join | :broadcast | :presence | :access_token | :postgres_changes
  @type transport :: :ws | :http
  @type kind :: :rejected | :internal_failure | :upstream_failure
  @type outcome :: :success | {kind(), atom()}

  @event [:realtime, :client_request]

  @doc """
  Returns the telemetry event name, [:realtime, :client_request].
  """
  def event, do: @event

  @doc """
  Runs `fun.()`, which must return `{result, outcome}`, and emits exactly one event.

  The outcome is recorded and `result` is returned untouched, so the caller gets the same channel
  callback result it would get without tracking.

  If `fun` raised, exited, or threw, `{:internal_failure, kind}` is emitted, where `kind` is `:error`,
  `:exit` or `:throw`. The exception is re-raised with `:erlang.raise/3` so the channel crashes
  exactly as it does today.
  """
  @spec track(request(), transport(), (-> {result, outcome()})) :: result when result: tuple()
  def track(request, transport, fun) do
    fun.()
  catch
    kind, reason ->
      record(request, transport, {:internal_failure, kind})
      :erlang.raise(kind, reason, __STACKTRACE__)
  else
    {result, outcome} ->
      record(request, transport, outcome)
      result
  end

  @doc """
  Emits one event for a request with the given outcome.

  A `:success` is recorded with the reason `:none`. A failure is recorded with the kind and
  reason it carries. `{:success, :none}` is not an outcome and raises `FunctionClauseError`.
  """
  @spec record(request(), transport(), outcome()) :: :ok
  def record(request, transport, :success) do
    emit(request, transport, :success, :none)
  end

  def record(request, transport, {kind, reason}) when kind != :success do
    emit(request, transport, kind, reason)
  end

  @doc """
  Maps a `BroadcastHandler` error code to an outcome.
  """
  @spec classify_broadcast_error(atom()) :: {kind(), atom()}
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

  defp emit(request, transport, outcome, reason) do
    :telemetry.execute(@event, %{count: 1}, %{
      request: request,
      transport: transport,
      outcome: outcome,
      reason: reason
    })
  end
end
