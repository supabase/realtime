defmodule Realtime.Resource do
  @moduledoc """
  Resources are used by the workflows interpreter to execute external tasks.
  """

  @callback can_handle(resource :: String.t()) :: boolean()
  @callback handle(resource :: String.ct(), ctx :: any(), args :: any()) :: {:ok, result :: any()} | {:error, reason :: term()}

  @doc """
  Returns the first resource handler that can handle `resource`.
  """
  def find_resource_handler(resource) do
    handler =
      resource_handlers()
      |> Enum.find(fn r -> r.can_handle(resource) end)
    case handler do
      nil -> :not_found
      handler -> {:ok, handler}
    end
  end

  ## Private

  defp resource_handlers do
    resource_config()
    |> Keyword.get(:resource_handlers, [])
  end

  defp resource_config do
    Application.get_env(:realtime, :workflows, [])
  end
end
