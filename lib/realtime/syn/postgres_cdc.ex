defmodule Realtime.Syn.PostgresCdc do
  @moduledoc """
  Scope for the PostgresCdc module.
  """

  @doc """
  Returns the scope for a given tenant id.
  """
  @spec scope(String.t()) :: atom()
  def scope(tenant_id) do
    shards = Application.fetch_env!(:realtime, :postgres_cdc_scope_shards)
    shard = :erlang.phash2(tenant_id, shards)
    :"realtime_postgres_cdc_#{shard}"
  end

  def scopes() do
    shards = Application.fetch_env!(:realtime, :postgres_cdc_scope_shards)
    Enum.map(0..(shards - 1), fn shard -> :"realtime_postgres_cdc_#{shard}" end)
  end

  def syn_topic_prefix(), do: "realtime_postgres_cdc_"
  def syn_topic(tenant_id), do: "#{syn_topic_prefix()}#{tenant_id}"
end
