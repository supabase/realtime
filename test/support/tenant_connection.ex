defmodule TenantConnection do
  @moduledoc """
  Boilerplate code to handle Realtime.Tenants.Connect during tests
  """
  alias Realtime.Api.Tenant

  def connect(%Tenant{} = tenant) do
    tenant
    |> then(&Realtime.PostgresCdc.filter_settings("postgres_cdc_rls", &1.extensions))
    |> then(fn settings -> Realtime.Database.from_settings(settings, "realtime_listen", :stop) end)
    |> Realtime.Database.connect_db()
  end

  def broadcast_test_message(conn, private, topic, event, payload) do
    query =
      """
      select pg_notify(
          'realtime:broadcast',
          json_build_object(
              'private', $1::boolean,
              'topic', $2::text,
              'event', $3::text,
              'payload', $4::jsonb
          )::text
      );
      """

    Postgrex.query!(conn, query, [private, topic, event, %{payload: payload}])
  end
end
