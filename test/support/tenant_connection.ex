defmodule TenantConnection do
  @moduledoc """
  Boilerplate code to handle Realtime.Tenants.Connect during tests
  """
  alias Realtime.Api.Message
  alias Realtime.Tenants.Repo
  alias Realtime.Tenants.Connect
  alias RealtimeWeb.Endpoint

  # OrioleDB logical decoding drops an INSERT made inside a SAVEPOINT (Postgrex `mode: :savepoint`)
  #
  # Repro on a `test_decoding` slot, OrioleDB table `m`:
  #   INSERT INTO m VALUES (1, 'top');                                                   -- decoded
  #   BEGIN; SAVEPOINT s; INSERT INTO m VALUES (2, 'sp'); RELEASE SAVEPOINT s; COMMIT;   -- dropped
  def create_message(attrs, conn, opts \\ []) do
    message = Message.changeset(%Message{}, attrs)

    case Repo.insert(conn, message, Message, opts) do
      {:ok, %Message{} = message} -> {:ok, message}
      %Ecto.Changeset{valid?: false} = error -> {:error, error}
      {:error, error} -> {:error, error}
    end
  end

  def ensure_connect_down(tenant_id) do
    # Using syn and not a normal Process.monitor because we want to ensure
    # that the process is down AND that the registry has been updated accordingly
    Endpoint.subscribe("connect:#{tenant_id}")

    if Connect.whereis(tenant_id) do
      Connect.shutdown(tenant_id)

      receive do
        %{event: "connect_down"} -> :ok
      after
        5000 ->
          if Connect.whereis(tenant_id) do
            raise "Connect process for tenant #{tenant_id} did not shut down in time"
          end
      end
    end
  after
    Endpoint.unsubscribe("connect:#{tenant_id}")
  end
end
