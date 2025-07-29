defmodule Realtime.Tenants.Connect.StartCounters do
  @moduledoc """
  Start tenant counters.
  """

  alias Realtime.RateCounter
  alias Realtime.Tenants

  @behaviour Realtime.Tenants.Connect.Piper

  @impl true
  def run(acc) do
    %{tenant: tenant} = acc

    with :ok <- start_joins_per_second_counter(tenant),
         :ok <- start_max_events_counter(tenant),
         :ok <- start_db_events_counter(tenant) do
      {:ok, acc}
    end
  end

  def start_joins_per_second_counter(tenant) do
    res =
      tenant
      |> Tenants.joins_per_second_rate()
      |> RateCounter.new()

    case res do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def start_max_events_counter(tenant) do
    res =
      tenant
      |> Tenants.events_per_second_rate()
      |> RateCounter.new()

    case res do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def start_db_events_counter(tenant) do
    res =
      tenant
      |> Tenants.db_events_per_second_rate()
      |> RateCounter.new()

    case res do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
