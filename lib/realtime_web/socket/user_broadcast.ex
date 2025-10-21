defmodule RealtimeWeb.Socket.UserBroadcast do
  @moduledoc """
  Defines a message sent from pubsub to channels and vice-versa.

  The message format requires the following keys:

    * `:topic` - The string topic or topic:subtopic pair namespace, for example "messages", "messages:123"
    * `:user_event`- The string user event name, for example "my-event"
    * `:payload_encoding`- :json or :binary
    * `:payload` - The actual message payload

  Optionally metadata which is an optional string encode as JSON

  """

  @type t :: %__MODULE__{}
  defstruct topic: nil, user_event: nil, payload: nil, payload_encoding: nil, metadata: nil
end
