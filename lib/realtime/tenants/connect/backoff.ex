defmodule Realtime.Tenants.Connect.Backoff do
  @moduledoc """
  Applies backoff on process initialization.
  """
  use GenServer

  @behaviour Realtime.Tenants.Connect.Piper

  @impl Realtime.Tenants.Connect.Piper
  def run(acc) do
    %{tenant_id: tenant_id} = acc

    case check(tenant_id) do
      {:ok, :block} -> {:error, :tenant_create_backoff}
      {:ok, :unblock} -> {:ok, acc}
    end
  end

  defp check(tenant_id), do: GenServer.call(__MODULE__, {:backoff_status, tenant_id})

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl GenServer
  def init(opts) do
    timer = Keyword.get(opts, :connect_backoff_timer)
    Process.send_after(self(), :countdown, timer)
    {:ok, %{timer: timer, tenants: %{}}}
  end

  @impl GenServer
  def handle_call({:backoff_status, tenant_id}, _from, %{tenants: tenants} = state) do
    if Map.get(tenants, tenant_id) do
      {:reply, {:ok, :block}, state}
    else
      {_, updated_tenants} =
        Map.get_and_update(tenants, tenant_id, fn
          nil -> {nil, true}
          _ -> {true, true}
        end)

      {:reply, {:ok, :unblock}, %{state | tenants: updated_tenants}}
    end
  end

  @impl GenServer
  def handle_info(:countdown, %{tenants: tenants, timer: timer} = state) do
    updated =
      tenants
      |> Enum.map(fn {tenant_id, _} -> {tenant_id, false} end)
      |> Map.new()

    Process.send_after(self(), :countdown, timer)

    {:noreply, %{state | tenants: updated}}
  end
end
