defmodule Realtime.ContextCache do
  @moduledoc """
    Read through cache for hot database paths.
  """

  require Logger

  def apply_fun(context, {fun, arity}, args) do
    cache = cache_name(context)
    cache_key = {{fun, arity}, args}

    case Cachex.fetch(cache, cache_key, fn {{_fun, _arity}, args} ->
           {:commit, {:cached, apply(context, fun, args)}}
         end) do
      {:commit, {:cached, value}} ->
        value

      {:ok, {:cached, value}} ->
        value
    end
  end

  defp cache_name(context) do
    Module.concat(context, Cache)
  end
end
