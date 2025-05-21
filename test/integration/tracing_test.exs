defmodule Realtime.Integration.TracingTest do
  # Async due to usage of global otel_simple_processor
  use RealtimeWeb.ConnCase, async: false

  @parent_id "b7ad6b7169203331"
  @traceparent "00-0af7651916cd43dd8448eb211c80319c-#{@parent_id}-01"
  @span_parent_id Integer.parse(@parent_id, 16) |> elem(0)

  # This is doing a blackbox approach because tracing is not captured with normal Phoenix controller tests

  test "traces basic HTTP request with phoenix and cowboy information" do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    url = RealtimeWeb.Endpoint.url() <> "/healthcheck"

    baggage_request_id = UUID.uuid4()

    response =
      Req.get!(url, headers: [{"traceparent", @traceparent}, {"baggage", "sb-request-id=#{baggage_request_id}"}])

    assert_receive {:span, span(name: "GET /healthcheck", attributes: attributes, parent_span_id: @span_parent_id)}

    assert attributes(
             map: %{
               "http.request.method": :GET,
               "http.response.status_code": 200,
               "http.route": "/healthcheck",
               "phoenix.action": :healthcheck,
               "phoenix.plug": RealtimeWeb.PageController,
               "url.path": "/healthcheck",
               "url.scheme": :http
             }
           ) = attributes

    assert %{"x-request-id" => [^baggage_request_id]} = response.headers
  end

  test "traces multiple spans" do
    tenant = Containers.checkout_tenant(run_migrations: true)
    jwt = Generators.generate_jwt_token(tenant)
    external_id = tenant.external_id

    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    url = RealtimeWeb.Endpoint.url() <> "/api/broadcast"

    body = %{"messages" => [%{"topic" => "le_topic", "payload" => %{"data" => "le"}, "event" => "le_event"}]}

    Req.post!(url,
      json: body,
      auth: {:bearer, jwt},
      headers: [{"host", "#{external_id}.example.com"}, {"traceparent", @traceparent}]
    )

    assert_receive {:span,
                    span(
                      span_id: span_id,
                      name: "POST /api/broadcast",
                      attributes: attributes,
                      parent_span_id: @span_parent_id
                    )}

    assert attributes(
             map: %{
               "http.request.method": :POST,
               "http.response.status_code": 202,
               "http.route": "/api/broadcast",
               "phoenix.action": :broadcast,
               "phoenix.plug": RealtimeWeb.BroadcastController,
               "url.path": "/api/broadcast",
               "url.scheme": :http,
               external_id: ^external_id
             }
           ) = attributes

    # child span of the previous span
    assert_receive {:span, span(name: "database.connect", attributes: attributes, parent_span_id: ^span_id)}

    assert attributes(map: %{external_id: ^external_id}) = attributes

    assert_receive {:span,
                    span(name: "realtime.repo.query:extensions", attributes: attributes, parent_span_id: ^span_id)}

    db_statement = """
    SELECT e0."id", e0."type", e0."settings", e0."tenant_external_id", e0."inserted_at", e0."updated_at", e0."tenant_external_id" FROM "extensions" AS e0 WHERE (e0."tenant_external_id" = $1) ORDER BY e0."tenant_external_id"\
    """

    assert attributes(
             map: %{
               source: "extensions",
               "db.name": "realtime_test",
               "db.type": :sql,
               "db.system": :postgresql,
               "db.statement": ^db_statement,
               query_time_microseconds: _
             }
           ) = attributes
  end
end
