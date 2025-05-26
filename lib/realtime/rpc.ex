defmodule Realtime.Rpc do
  @moduledoc """
  RPC module for Realtime with the intent of standardizing the RPC interface, collect telemetry and opentelemetry tracing spans
  """
  import Realtime.Logs
  alias Realtime.Telemetry
  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Calls external node using :rpc.call/5 and collects telemetry
  """
  @spec call(atom(), atom(), atom(), any(), keyword()) :: any()
  def call(node, mod, func, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:realtime, :rpc_timeout))
    {latency, response} = :timer.tc(fn -> :rpc.call(node, mod, func, args, timeout) end)

    Telemetry.execute(
      [:realtime, :rpc],
      %{latency: latency},
      %{mod: mod, func: func, target_node: node, origin_node: node()}
    )

    response
  end

  @doc """
  Calls external node using :erpc.call/5, collecting telemetry and optionally collecting opentelemetry trace spans.

  ## Options

    * `:timeout` - Upper time limit for call operations to complete. Default: `:infinity`;
    * `:tracing_span_name` - If present the call is instrumented;
    * `:tenant` - If present and there is a `tracing_span_name` then an `external_id` span attribute is set.
  """
  @spec enhanced_call(atom(), atom(), atom(), any(), keyword()) ::
          {:ok, any()} | {:error, :rpc_error, term()} | {:error, term()}
  def enhanced_call(node, mod, func, args \\ [], opts \\ []) do
    with {latency, response} <-
           :timer.tc(fn -> erpc_call(node, mod, func, args, opts) end) do
      case response do
        {:ok, _} ->
          Telemetry.execute(
            [:realtime, :rpc],
            %{latency: latency},
            %{mod: mod, func: func, target_node: node, origin_node: node(), success: true}
          )

          response

        {:error, error} ->
          Telemetry.execute(
            [:realtime, :rpc],
            %{latency: latency},
            %{mod: mod, func: func, target_node: node, origin_node: node(), success: false}
          )

          {:error, error}
      end
    end
  catch
    _, reason ->
      reason =
        case reason do
          {_, reason} -> reason
          {_, reason, _} -> reason
        end

      Telemetry.execute(
        [:realtime, :rpc],
        %{latency: 0},
        %{mod: mod, func: func, target_node: node, origin_node: node(), success: false}
      )

      log_error(
        "ErrorOnRpcCall",
        %{target: node, mod: mod, func: func, error: reason},
        mod: mod,
        func: func,
        target: node
      )

      {:error, :rpc_error, reason}
  end

  defp erpc_call(node, mod, func, args, opts) do
    timeout = Keyword.get(opts, :timeout, Application.get_env(:realtime, :rpc_timeout))
    tracing_span_name = Keyword.get(opts, :tracing_span_name)
    tenant = Keyword.get(opts, :tenant)

    if tracing_span_name do
      trace_erpc_call(node, {mod, func, args}, tracing_span_name, tenant, timeout)
    else
      :erpc.call(node, mod, func, args, timeout)
    end
  end

  # Fully local call
  defp trace_erpc_call(node, {mod, func, args}, span_name, _tenant, timeout) when node() == node do
    span_ctx = Tracer.start_span("local.#{span_name}")
    ctx = OpenTelemetry.Ctx.get_current()

    :erpc.call(node, __MODULE__, :local_traced_apply, [mod, func, args, {ctx, span_ctx}], timeout)
  end

  defp trace_erpc_call(node, {mod, func, args}, span_name, tenant, timeout) do
    attributes =
      build_attributes(mod, func, args, tenant)
      |> Keyword.put(:node, node)

    otel_propagation_headers = :otel_propagator_text_map.inject([])

    Tracer.with_span "remote.#{span_name}", %{attributes: attributes} do
      :erpc.call(
        node,
        __MODULE__,
        :remote_traced_apply,
        [mod, func, args, span_name, otel_propagation_headers],
        timeout
      )
    end
  end

  @doc false
  # Used by this module to decorate the remote call with opentelemetry span
  def remote_traced_apply(mod, func, args, span_name, otel_propagation_headers) do
    attributes = build_attributes(mod, func, args)
    :otel_propagator_text_map.extract(otel_propagation_headers)

    Tracer.with_span "local.#{span_name}", %{attributes: attributes} do
      :erlang.apply(mod, func, args)
    end
  end

  @doc false
  # Used by this module to decorate the local call with opentelemetry span
  def local_traced_apply(mod, func, args, {ctx, span_ctx}) do
    attributes = build_attributes(mod, func, args)
    OpenTelemetry.Ctx.attach(ctx)
    Tracer.set_current_span(span_ctx)
    Tracer.set_attributes(attributes)

    :erlang.apply(mod, func, args)
  after
    OpenTelemetry.Span.end_span(span_ctx)
  end

  defp build_attributes(mod, func, args, tenant \\ nil) do
    attributes = [mod: mod, func: func, arity: length(args)]

    if tenant do
      Keyword.put(attributes, :external_id, tenant)
    else
      attributes
    end
  end
end
