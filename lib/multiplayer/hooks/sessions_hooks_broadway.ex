defmodule Multiplayer.SessionsHooksBroadway do
  use Broadway
  require Logger

  alias Broadway.Message
  @headers [{"content-type", "application/json"}]

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: MultiplayerSessionsHooks,
      producer: [
        module: {Multiplayer.SessionsHooksProducer, []},
        transformer: {__MODULE__, :transform, []},
        # the producer does not support concurrency
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 10, max_demand: 1]
      ]
    )
  end

  @impl true
  def handle_message(_, %Message{data: data} = message, _state) do
    payload = Jason.encode!(%{"user_id" => data.user_id})

    case data.event do
      "session.connected" ->
        response = HTTPoison.post(data.url, payload, @headers)

        with {:ok, %{status_code: 200, body: body_data}} <- response,
             {:ok, %{"data" => "accepted"}} <- Jason.decode(body_data) do
          send(data.pid, {:rls, :accepted})
        else
          error ->
            Logger.debug("SessionsHooksBroadway post error response: #{error}")
            :ok
        end

      "session.disconnected" ->
        HTTPoison.post(data.url, payload, @headers)

      undef ->
        Logger.error("Undefined event: #{inspect(undef)}")
    end

    message
  end

  def transform(event, _opts) do
    %Message{
      data: event,
      acknowledger: {__MODULE__, :ack_id, :ack_data}
    }
  end

  def ack(:ack_id, _successful, _failed) do
    :ok
  end
end
