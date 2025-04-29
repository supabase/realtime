defmodule Realtime.Tenants.Connect.Backoff do
  @moduledoc """
  Applies backoff on process initialization.
  """
  alias Realtime.RateCounter
  alias Realtime.GenCounter
  alias Realtime.Tenants
  @behaviour Realtime.Tenants.Connect.Piper

  @impl Realtime.Tenants.Connect.Piper
  def run(acc) do
    %{tenant_id: tenant_id} = acc
    connect_backoff_limit = Application.get_env(:realtime, :connect_backoff_limit)

    with {:ok, counter} <- start_connects_per_second_counter(tenant_id, connect_backoff_limit),
         {:ok, %{avg: avg}} when avg < connect_backoff_limit <- RateCounter.get(counter) do
      GenCounter.add(counter)
      {:ok, acc}
    else
      _ -> {:error, :tenant_create_backoff}
    end
  end

  defp start_connects_per_second_counter(tenant_id, limit) do
    id = Tenants.connection_attempts_per_second_key(tenant_id)
    GenCounter.new(id)

    res =
      RateCounter.new(id,
        idle_shutdown: :infinity,
        telemetry: %{
          event_name: [:channel, :joins],
          measurements: %{limit: limit},
          metadata: %{tenant: tenant_id},
          tick: 500
        }
      )

    case res do
      {:ok, _} -> {:ok, id}
      {:error, {:already_started, _}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
    end
  end
end
