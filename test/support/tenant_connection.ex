defmodule TenantConnection do
  @moduledoc """
  Boilerplate code to handle Realtime.Tenants.Connect during tests
  """

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
