defmodule Realtime.Resource.Http do
  @moduledoc """
  This resource handler executes HTTP calls and returns their response.

  ## Arguments

   * `url` - The request URL
   * `method` - The request HTTP method
   * `headers` - A map of key-values that will be added to the request headers
   * `body` - The request body

  ## Result

   * `headers` - The response headers
   * `status_code` - The response status code
   * `body` - The response body
  """
  require Logger

  alias Realtime.Resource

  @behaviour Resource

  def can_handle(resource) do
    resource == "http"
  end

  # TODO: make this better
  def handle(resource, _ctx, args) do
    Logger.info("Calling http resource #{inspect(resource)} with args #{inspect(args)}")

    headers = [{"Content-Type", "application/json"}]
    %{"method" => _method, "url" => url} = args
    HTTPoison.post(url, Jason.encode!(args["payload"] || %{}), headers)
  end
end
