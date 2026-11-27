defmodule RealtimeWeb.RequestMetrics do
  @moduledoc """
  Records one outcome per client request, or one per message for a request that carries several.

  Every request, or message, ends in exactly one of four outcomes:

    * `:success` - handled
    * `:rejected` - refused because of the client's request: policy deny, payload too large,
      or rate limit
    * `:internal_failure` - Realtime failed: a crash or an unexpected error
    * `:upstream_failure` - a dependency failed: tenant database or connection pool

  An outcome is a value, either `:success` or `{kind, reason}`. The code that handles a request
  returns its outcome next to its result, and `track/4` records it. Nothing is stored on the
  socket. A success has no reason of its own, so the reason `:none` appears only on a success.
  """

  @type request :: :join | :broadcast | :presence | :access_token | :postgres_changes
  @type transport :: :ws | :http
  @type kind :: :rejected | :internal_failure | :upstream_failure
  @type outcome :: :success | {kind(), atom()}
  @type outcomes :: outcome() | [outcome()]
  @type tenant :: String.t()

  @event [:realtime, :client_request]

  # Error codes of the broadcast endpoints, by the kind of outcome they give. A code that's not
  # in either list is an internal failure.
  @rejected [
    :unauthorized,
    :invalid_request,
    :tenant_suspended,
    :rate_limit_exceeded,
    :payload_size_exceeded,
    :persistence_invalid_ttl,
    :persistence_unauthorized,
    :batch_rejected
  ]

  @upstream_failures [
    :rls_policy_error,
    :query_canceled,
    :unable_to_connect_to_project,
    :database_lack_of_connections,
    :database_connection_rate_limit_reached,
    :initializing_project_connection,
    :increase_connection_pool,
    :persistence_failed
  ]

  @doc """
  Returns the telemetry event name, [:realtime, :client_request].

  The metadata carries `:request`, `:transport`, `:outcome`, `:reason` and `:tenant`.
  """
  def event, do: @event

  @doc """
  Runs `fun.()`, which must return `{result, outcomes}`, and emits one event for each outcome.

  `outcomes` is one outcome, or a list of them for a request that carries several messages. The
  outcomes are recorded and `result` is returned untouched, so the caller gets the same result it
  would get without tracking.

  If `fun` raised, exited, or threw, `{:internal_failure, kind}` is emitted, where `kind` is `:error`,
  `:exit` or `:throw`. The exception is re-raised with `:erlang.raise/3` so the caller crashes
  exactly as it does today.
  """
  @spec track(request(), transport(), tenant(), (-> {result, outcomes()})) :: result when result: term()
  def track(request, transport, tenant, fun) do
    fun.()
  catch
    kind, reason ->
      record(request, transport, tenant, {:internal_failure, kind})
      :erlang.raise(kind, reason, __STACKTRACE__)
  else
    {result, outcomes} ->
      outcomes |> List.wrap() |> Enum.each(&record(request, transport, tenant, &1))
      result
  end

  @doc """
  Emits one event for a request with the given outcome.

  A `:success` is recorded with the reason `:none`. A failure is recorded with the kind and
  reason it carries. `{:success, :none}` is not an outcome and raises `FunctionClauseError`.
  """
  @spec record(request(), transport(), tenant(), outcome()) :: :ok
  def record(request, transport, tenant, :success) do
    emit(request, transport, tenant, :success, :none)
  end

  def record(request, transport, tenant, {kind, reason}) when kind != :success do
    emit(request, transport, tenant, kind, reason)
  end

  @doc """
  Maps a broadcast error code to an outcome.

  A code that is not in `broadcast_error_codes/0` is an internal failure.
  """
  @spec classify_broadcast_error(atom()) :: {kind(), atom()}
  def classify_broadcast_error(code) when code in @rejected, do: {:rejected, code}
  def classify_broadcast_error(code) when code in @upstream_failures, do: {:upstream_failure, code}
  def classify_broadcast_error(code), do: {:internal_failure, code}

  @doc """
  Returns the error codes that are not internal failures, by the kind of outcome they give.
  """
  @spec broadcast_error_codes() :: %{rejected: [atom()], upstream_failure: [atom()]}
  def broadcast_error_codes, do: %{rejected: @rejected, upstream_failure: @upstream_failures}

  @doc """
  Maps an error from the tenant database or from the authorization check to an outcome.

  Both HTTP broadcast endpoints use this function. `error` is the value that `Connect` or
  `Authorization.get_write_authorizations/3` returns, in either of its two error shapes.
  """
  @spec classify_authorization_error(term()) :: {kind(), atom()}
  def classify_authorization_error(error), do: error |> authorization_error_code() |> classify_broadcast_error()

  defp authorization_error_code({:error, :tenant_database_unavailable}), do: :unable_to_connect_to_project

  defp authorization_error_code({:error, reason})
       when reason in [:initializing, :tenant_database_connection_initializing],
       do: :initializing_project_connection

  defp authorization_error_code({:error, :tenant_db_too_many_connections}), do: :database_lack_of_connections
  defp authorization_error_code({:error, :connect_rate_limit_reached}), do: :database_connection_rate_limit_reached
  defp authorization_error_code({:error, :increase_connection_pool}), do: :increase_connection_pool
  defp authorization_error_code({:error, :missing_partition}), do: :missing_partition
  defp authorization_error_code({:error, :rpc_error, _}), do: :unable_to_handle_broadcast
  defp authorization_error_code({:error, :rls_policy_error, _}), do: :rls_policy_error
  defp authorization_error_code({:error, :query_canceled, _}), do: :query_canceled
  defp authorization_error_code(_error), do: :unable_to_set_policies

  defp emit(request, transport, tenant, outcome, reason) do
    :telemetry.execute(@event, %{count: 1}, %{
      request: request,
      transport: transport,
      outcome: outcome,
      reason: reason,
      tenant: tenant
    })
  end
end
