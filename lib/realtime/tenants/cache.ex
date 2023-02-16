defmodule Realtime.Tenants.Cache do
  @moduledoc """
  Cache for Tenants.
  """

  require Cachex.Spec

  alias Realtime.Tenants

  def child_spec(_) do
    %{
      id: __MODULE__,
      start:
        {Cachex, :start_link, [__MODULE__, [expiration: Cachex.Spec.expiration(default: 30_000)]]}
    }
  end

  def get_tenant_by_external_id(keyword), do: apply_repo_fun(__ENV__.function, [keyword])

  defp apply_repo_fun(arg1, arg2) do
    Realtime.ContextCache.apply_fun(Tenants, arg1, arg2)
  end
end
