defmodule Realtime.Tenants.AutoUnsuspend do
  @moduledoc """
  Periodically unsuspends tenants whose auto_unsuspend_at timestamp has passed.
  Runs on all nodes — Api.update_tenant_by_external_id handles master-region routing.
  """

  use GenServer
  require Logger
  import Ecto.Query

  alias Realtime.Api.Tenant
  alias Realtime.Repo.Replica
  alias Realtime.Tenants

  @default_interval :timer.minutes(1)

  def start_link(opts \\ []) do
    interval = Keyword.get(opts, :check_interval_ms, @default_interval)
    GenServer.start_link(__MODULE__, %{interval: interval}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    schedule(state.interval)
    {:ok, state}
  end

  @impl true
  def handle_info(:check, state) do
    perform_check()
    schedule(state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(_, state), do: {:noreply, state}

  def perform_check do
    now = DateTime.utc_now()
    repo = Replica.replica()

    Tenant
    |> where([t], t.suspend == true and not is_nil(t.auto_unsuspend_at) and t.auto_unsuspend_at <= ^now)
    |> select([t], t.external_id)
    |> repo.all()
    |> Enum.each(fn external_id ->
      Logger.info("AutoUnsuspend: unsuspending #{external_id}")

      case Tenants.auto_unsuspend_tenant_by_external_id(external_id) do
        {:ok, _} -> :ok
        {:error, reason} -> Logger.error("AutoUnsuspend failed for #{external_id}: #{inspect(reason)}")
      end
    end)
  end

  defp schedule(ms), do: Process.send_after(self(), :check, ms)
end
