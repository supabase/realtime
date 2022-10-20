defmodule Realtime.PostgresCdc do
  @moduledoc false

  def connect(module, opts) do
    Kernel.apply(module, :handle_connect, [opts])
  end

  def after_connect(module, opts) do
    Kernel.apply(module, :handle_after_connect, [opts])
  end

  def subscribe(module, pg_change_params, tenant, metadata) do
    Kernel.apply(module, :handle_subscribe, [pg_change_params, tenant, metadata])
  end

  def filter_settings(key, extensions) do
    [cdc] =
      Enum.filter(extensions, fn e ->
        if e.type == key do
          true
        else
          false
        end
      end)

    cdc.settings
  end

  def driver(tenant_key) do
    Application.get_env(:realtime, :extensions)
    |> Enum.filter(fn {_, %{key: key}} -> tenant_key == key end)
    |> case do
      [{_, %{driver: driver}}] -> {:ok, driver}
      _ -> {:error, "No driver found for key #{tenant_key}"}
    end
  end

  @callback handle_connect(map()) :: {:ok, pid()} | {:error, any()}
  @callback handle_after_connect(map()) :: {:ok, any()} | {:error, any()}
  @callback handle_subscribe(list(), String.t(), map()) :: :ok
end
