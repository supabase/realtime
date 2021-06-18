defmodule Realtime.Resource.Email do
  @moduledoc """

  This resource handler executes email calls and returns their provider responses.

  ## Required Arguments

    * `to` - Email recipient
    * `from` - Email sender

  ## Optional Arguments

    * `subject` - Email subject (e.g. "Open Immediately")
    * `html_body` - Email html body (e.g. "<strong>Hey there!</strong>")
    * `text_body` - Email text body (e.g. "Hey there!")

  ## Result

    TBD by SMTP service provider

  """

  import Bamboo.Email

  require Logger

  alias Realtime.Resource

  @behaviour Resource
  @allowed_args ["to", "from", "subject", "html_body", "text_body"]

  defmodule Mailer do
    use Bamboo.Mailer, otp_app: :realtime
  end

  def can_handle("email"), do: true
  def can_handle(_), do: false

  # TODO: make this better and add more email args to @allowed_args
  def handle(resource, _ctx, %{"payload" => payload} = args) when is_map(payload) do
    Logger.info("Calling email resource #{inspect(resource)} with args #{inspect(args)}")

    payload
    |> Map.update("text_body", "", fn body ->
      # testing purposes
      case Jason.encode(body) do
        {:ok, encoded_body} -> encoded_body
        {:error, _error} -> body
      end
    end)
    |> Map.take(@allowed_args)
    |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put(acc, String.to_atom(k), v) end)
    |> Map.to_list()
    |> new_email()
    |> Mailer.deliver_now(response: true)
    |> case do
      {:ok, _email, response} -> {:ok, response}
      {:error, error} -> {:error, error}
    end
  end

  def handle(_resource, _ctx, _args), do: {:error, :payload_error}
end
