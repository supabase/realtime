defmodule Realtime.Interpreter.ResourceHandler do

  require Logger

  alias Realtime.Resource

  def handle_resource(resource, ctx, args) do
    case Resource.find_resource_handler(resource) do
      {:ok, handler} ->
	handler.handle(resource, ctx, args)
      :not_found ->
	{:error, :resource_handler_not_found}
    end
  end
end
