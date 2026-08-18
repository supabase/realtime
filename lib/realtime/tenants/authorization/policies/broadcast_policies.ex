defmodule Realtime.Tenants.Authorization.Policies.BroadcastPolicies do
  @moduledoc """
  BroadcastPolicies structure that holds the required authorization information for a given connection within the scope of a sending / receiving broadcasts messages

  `persist` holds whether the broadcasts of a given Topic may be stored in `realtime.messages`.
  """
  defstruct read: nil, write: nil, persist: nil

  @type t :: %__MODULE__{
          read: boolean() | nil,
          write: boolean() | nil,
          persist: boolean() | nil
        }
end
