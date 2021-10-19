defmodule Multiplayer.SessionsHooksBroadway do
  use Broadway
  require Logger

  alias Broadway.Message

  def start_link(_opts) do
    Broadway.start_link(__MODULE__,
      name: MultiplayerSessionsHooks,
      producer: [
        module: {Multiplayer.SessionsHooksProducer, []},
        transformer: {__MODULE__, :transform, []},
      ],
      processors: [
        default: [concurrency: 10, max_demand: 1]
      ],
      batchers: [
        webhooks: [batch_size: 1]
      ]
    )
  end

  @impl true
  def handle_message(_, %Message{} = message, _state) do
    message |> Message.put_batcher(:webhooks)
  end

  @impl true
  def handle_batch(:webhooks, messages, _batch_info, _state) do
    messages
  end

  def handle_batch(name, _messages, _batch_info, _state) do
    Logger.error("Undefined handle_batch", name)
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
