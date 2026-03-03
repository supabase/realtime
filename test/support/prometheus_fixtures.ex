defmodule PrometheusFixtures do
  @moduledoc """
  Realistic Prometheus text-format payloads matching what Realtime's PromEx
  plugins actually emit. Use these in tests for PrometheusRemoteWrite and
  MetricsPusher to ensure encoding handles real production metric shapes.
  """

  @timestamp 1_700_000_000_000

  def timestamp, do: @timestamp

  def beam_metrics do
    """
    # HELP beam_memory_bytes The amount of memory currently allocated
    # TYPE beam_memory_bytes gauge
    beam_memory_bytes{type="total"} 52428800.0 #{@timestamp}
    beam_memory_bytes{type="processes"} 20971520.0 #{@timestamp}
    beam_memory_bytes{type="binary"} 1048576.0 #{@timestamp}
    beam_memory_bytes{type="ets"} 2097152.0 #{@timestamp}
    # HELP beam_stats_run_queue_count Run queue count
    # TYPE beam_stats_run_queue_count gauge
    beam_stats_run_queue_count{queue="cpu"} 0.0 #{@timestamp}
    beam_stats_run_queue_count{queue="io"} 1.0 #{@timestamp}
    # HELP beam_stats_context_switches_total Total context switches
    # TYPE beam_stats_context_switches_total counter
    beam_stats_context_switches_total 483921.0 #{@timestamp}
    # HELP beam_stats_reductions_total Total reductions executed
    # TYPE beam_stats_reductions_total counter
    beam_stats_reductions_total 987654321.0 #{@timestamp}
    # EOF
    """
  end

  def phoenix_metrics do
    """
    # HELP phoenix_endpoint_duration_seconds The duration of the endpoint request pipeline
    # TYPE phoenix_endpoint_duration_seconds histogram
    phoenix_endpoint_duration_seconds_bucket{method="GET",route="/api/tenants/:tenant_id/realtime/v1/websocket",status="101",le="0.01"} 5 #{@timestamp}
    phoenix_endpoint_duration_seconds_bucket{method="GET",route="/api/tenants/:tenant_id/realtime/v1/websocket",status="101",le="0.1"} 43 #{@timestamp}
    phoenix_endpoint_duration_seconds_bucket{method="GET",route="/api/tenants/:tenant_id/realtime/v1/websocket",status="101",le="1.0"} 100 #{@timestamp}
    phoenix_endpoint_duration_seconds_bucket{method="GET",route="/api/tenants/:tenant_id/realtime/v1/websocket",status="101",le="+Inf"} 100 #{@timestamp}
    phoenix_endpoint_duration_seconds_sum{method="GET",route="/api/tenants/:tenant_id/realtime/v1/websocket",status="101"} 12 #{@timestamp}
    phoenix_endpoint_duration_seconds_count{method="GET",route="/api/tenants/:tenant_id/realtime/v1/websocket",status="101"} 100 #{@timestamp}
    phoenix_endpoint_duration_seconds_bucket{method="GET",route="/metrics",status="200",le="0.01"} 10 #{@timestamp}
    phoenix_endpoint_duration_seconds_bucket{method="GET",route="/metrics",status="200",le="+Inf"} 10 #{@timestamp}
    phoenix_endpoint_duration_seconds_sum{method="GET",route="/metrics",status="200"} 1 #{@timestamp}
    phoenix_endpoint_duration_seconds_count{method="GET",route="/metrics",status="200"} 10 #{@timestamp}
    # EOF
    """
  end

  def tenant_connection_metrics do
    """
    # HELP realtime_connections_connected The node total count of connected clients for a tenant
    # TYPE realtime_connections_connected gauge
    realtime_connections_connected{tenant="tenant-abc-123"} 42.0 #{@timestamp}
    realtime_connections_connected{tenant="tenant-xyz-456"} 7.0 #{@timestamp}
    # HELP realtime_connections_connected_cluster The cluster total count of connected clients for a tenant
    # TYPE realtime_connections_connected_cluster gauge
    realtime_connections_connected_cluster{tenant="tenant-abc-123"} 130.0 #{@timestamp}
    realtime_connections_connected_cluster{tenant="tenant-xyz-456"} 21.0 #{@timestamp}
    # EOF
    """
  end

  def tenant_payload_metrics do
    """
    # HELP realtime_tenants_payload_size_bytes Tenant payload size
    # TYPE realtime_tenants_payload_size_bytes histogram
    realtime_tenants_payload_size_bytes_bucket{message_type="broadcast",tenant="tenant-abc-123",le="250.0"} 80 #{@timestamp}
    realtime_tenants_payload_size_bytes_bucket{message_type="broadcast",tenant="tenant-abc-123",le="500.0"} 95 #{@timestamp}
    realtime_tenants_payload_size_bytes_bucket{message_type="broadcast",tenant="tenant-abc-123",le="1000.0"} 100 #{@timestamp}
    realtime_tenants_payload_size_bytes_bucket{message_type="broadcast",tenant="tenant-abc-123",le="+Inf"} 100 #{@timestamp}
    realtime_tenants_payload_size_bytes_sum{message_type="broadcast",tenant="tenant-abc-123"} 32000 #{@timestamp}
    realtime_tenants_payload_size_bytes_count{message_type="broadcast",tenant="tenant-abc-123"} 100 #{@timestamp}
    # EOF
    """
  end

  def channel_error_metrics do
    """
    # HELP realtime_channel_error Count of errors in the Realtime channels initialization
    # TYPE realtime_channel_error counter
    realtime_channel_error{code="tenant_not_found"} 3.0 #{@timestamp}
    realtime_channel_error{code="too_many_connections"} 1.0 #{@timestamp}
    # EOF
    """
  end

  def full_global_payload do
    [beam_metrics(), phoenix_metrics(), channel_error_metrics()]
    |> Enum.join()
  end

  def full_tenant_payload do
    [tenant_connection_metrics(), tenant_payload_metrics()]
    |> Enum.join()
  end
end
