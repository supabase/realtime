defmodule Multiplayer.HooksBroadway do
  use Broadway

  alias Broadway.Message

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: MultiplayerExample,
      producer: [
        module: {Multiplayer.HooksProducer, []},
        transformer: {__MODULE__, :transform, []},
        rate_limiting: [
          interval: 1_000,
          allowed_messages: 1
        ]
      ],
      processors: [
        default: [concurrency: 3, max_demand: 1]
      ]
    )
  end

  def handle_message(:default, %Message{data: _data} = message, _state) do
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
