defmodule Extensions.AiAgent.SessionSupervisorTest do
  use ExUnit.Case, async: false

  alias Extensions.AiAgent.SessionSupervisor

  @encrypted_key Realtime.Crypto.encrypt!("sk-test")

  @base_opts [
    tenant_id: "test-tenant",
    tenant_topic: "test-tenant:private:agent:chat",
    settings: %{
      "protocol" => "openai_compatible",
      "base_url" => "https://api.openai.com/v1",
      "model" => "gpt-4o",
      "api_key" => @encrypted_key
    }
  ]

  defp spawn_channel do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  describe "start_session/1" do
    test "starts a session and returns pid" do
      opts = Keyword.put(@base_opts, :channel_pid, spawn_channel())
      assert {:ok, pid} = SessionSupervisor.start_session(opts)
      assert is_pid(pid)
      assert Process.alive?(pid)
    end
  end
end
