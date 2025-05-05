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
    connect_throttle_limit_per_second = Application.fetch_env!(:realtime, :connect_throttle_limit_per_second)

    with {:ok, counter} <- start_connects_per_second_counter(tenant_id),
         {:ok, %{avg: avg}} when avg <= connect_throttle_limit_per_second <- RateCounter.get(counter) do
      GenCounter.add(counter)
      {:ok, acc}
    else
      _ -> {:error, :tenant_create_backoff}
    end
  end

  defp start_connects_per_second_counter(tenant_id) do
    id = Tenants.connection_attempts_per_second_key(tenant_id)

    case RateCounter.get(id) do
      {:ok, _} ->
        :ok

      {:error, _} ->
        GenCounter.new(id)
        RateCounter.new(id, idle_shutdown: :infinity, tick: 100, idle_shutdown_ms: :timer.minutes(5))
    end

    {:ok, id}
  end
end
