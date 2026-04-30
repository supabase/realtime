defmodule Extensions.AiAgent.Types.Event do
  @moduledoc """
  Internal envelope for events streamed from an AI provider to a Session.
  Each event maps 1:1 to a broadcast sent to the client channel topic.
  """

  @type event_type ::
          :session_started
          | :text_delta
          | :thinking_delta
          | :tool_call_delta
          | :tool_call_done
          | :usage
          | :done
          | :error
          | :rate_limit

  @type t :: %__MODULE__{type: event_type(), payload: map()}

  @enforce_keys [:type, :payload]
  defstruct [:type, :payload]

  @doc "Returns the broadcast event name for a given event type."
  @spec broadcast_event(t()) :: String.t()
  def broadcast_event(%__MODULE__{type: type}) do
    "agent_" <> Atom.to_string(type)
  end
end
