defmodule Extensions.AiAgent.AiPoliciesTest do
  use ExUnit.Case, async: true

  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.AiPolicies

  describe "AiPolicies struct" do
    test "defaults both permissions to nil" do
      assert %AiPolicies{read: nil, write: nil} = %AiPolicies{}
    end
  end

  describe "Policies struct includes ai_agent" do
    test "defaults ai_agent to empty AiPolicies" do
      assert %Policies{ai_agent: %AiPolicies{read: nil, write: nil}} = %Policies{}
    end

    test "update_policies sets ai_agent write" do
      policies = Policies.update_policies(%Policies{}, :ai_agent, :write, true)
      assert %Policies{ai_agent: %AiPolicies{write: true}} = policies
    end

    test "update_policies sets ai_agent read" do
      policies = Policies.update_policies(%Policies{}, :ai_agent, :read, false)
      assert %Policies{ai_agent: %AiPolicies{read: false}} = policies
    end
  end
end
