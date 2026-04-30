defmodule Extensions.AiAgent.AiPoliciesTest do
  use ExUnit.Case, async: true

  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.Authorization.Policies.AiPolicies

  describe "AiPolicies struct" do
    test "new Policies has no AI write access — events are rejected until RLS grants it" do
      assert %Policies{ai_agent: %AiPolicies{write: nil}} = %Policies{}
      refute match?(%Policies{ai_agent: %AiPolicies{write: true}}, %Policies{})
    end
  end

  describe "Policies struct includes ai_agent" do
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
