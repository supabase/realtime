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
        concurrency: 1 # the producer does not support concurrency
      ],
      processors: [
        default: [concurrency: 10, max_demand: 1]
      ]
    )
  end

  @impl true
  def handle_message(_, %Message{data: data} = message, _state) do
    case data.event do
      "session.connected" ->
        payload = Jason.encode!(%{"user_id" => data.user_id})
        #TODO: handle a response
        _ = HTTPoison.post(data.url, payload, @headers)
        send(data.pid, {:rls, :accepted})
        message
      undef ->
        Logger.error("Undefined event: #{inspect(undef)}")
        message
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
