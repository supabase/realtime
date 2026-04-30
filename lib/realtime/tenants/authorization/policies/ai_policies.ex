defmodule Realtime.Tenants.Authorization.Policies.AiPolicies do
  @moduledoc """
  AiPolicies structure that holds the required authorization information for a given connection
  within the scope of sending inputs to and receiving broadcasts from an AI agent.
  """
  defstruct read: nil, write: nil

  @type t :: %__MODULE__{
          read: boolean() | nil,
          write: boolean() | nil
        }
end
