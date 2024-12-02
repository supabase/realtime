defmodule Realtime.Tenants.Authorization.Policies.BroadcastPolicies do
  @moduledoc """
  BroadcastPolicies structure that holds the required authorization information for a given connection within the scope of a sending / receiving broadcasts messages
  """
  require Logger

  defstruct read: false, write: false

  @type t :: %__MODULE__{
          read: boolean(),
          write: boolean()
        }
end
