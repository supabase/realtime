defmodule Realtime.PostgresCdc do
  @moduledoc false

  def connect(module, opts) do
    apply(module, :handle_connect, [opts])
  end

  def after_connect(module, connect_response, extension, params) do
    apply(module, :handle_after_connect, [connect_response, extension, params])
  end

  def subscribe(module, pg_change_params, tenant, metadata) do
    apply(module, :handle_subscribe, [pg_change_params, tenant, metadata])
  end

  def stop(module, tenant, timeout \\ 10_000) do
    apply(module, :handle_stop, [tenant, timeout])
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

  def aws_to_fly(aws_region) do
    case aws_region do
      "us-east-1" -> "iad"
      "us-west-1" -> "iad"
      "sa-east-1" -> "gru"
      "ca-central-1" -> "iad"
      "ap-southeast-1" -> "sin"
      "ap-northeast-1" -> "sin"
      "ap-northeast-2" -> "sin"
      "ap-southeast-2" -> "sin"
      "ap-south-1" -> "sin"
      "eu-west-1" -> "fra"
      "eu-west-2" -> "fra"
      "eu-central-1" -> "fra"
      _ -> nil
    end
  end

  def region_nodes(region) do
    :syn.members(RegionNodes, region)
  end

  @callback handle_connect(any()) :: {:ok, pid()} | {:error, any()}
  @callback handle_after_connect(any(), any(), any()) :: {:ok, any()} | {:error, any()}
  @callback handle_subscribe(any(), any(), any()) :: :ok
end
