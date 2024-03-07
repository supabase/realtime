defmodule Realtime.Channels.Cache do
  @moduledoc """
  Cache for Channels.
  """
  require Cachex.Spec

  alias Realtime.Channels

  def child_spec(_) do
    %{
      id: __MODULE__,
      start:
        {Cachex, :start_link, [__MODULE__, [expiration: Cachex.Spec.expiration(default: 30_000)]]}
    }
  end

  def get_channel_by_name(name, db_conn), do: apply_repo_fun(__ENV__.function, [name, db_conn])

  defp apply_repo_fun(function, args) do
    Realtime.ContextCache.apply_fun(Channels, function, args)
  end
end
