defmodule TestTenantDb.Backend.DockerTest do
  # async: false — these tests swap the :test_run_tag app env that TestTenantDb reads to name
  # and reap its containers.
  use ExUnit.Case, async: false

  alias Realtime.Env
  alias TestTenantDb.Backend.Docker

  @suffix String.duplicate("a", 12)

  defp put_run_tag(tag) do
    original = Application.fetch_env!(:realtime, :test_run_tag)
    Application.put_env(:realtime, :test_run_tag, tag)
    on_exit(fn -> Application.put_env(:realtime, :test_run_tag, original) end)
  end

  describe "container_prefix/0 and container_name/0" do
    test "the first run on a machine names containers as it always did" do
      put_run_tag("")

      assert Docker.container_prefix() == "realtime-test"
      assert Docker.container_name() =~ ~r"^realtime-test-.{12}$"
    end

    test "a second run puts its endpoint port in the name" do
      put_run_tag("_port4003")

      assert Docker.container_prefix() == "realtime-test_port4003"
      assert Docker.container_name() =~ ~r"^realtime-test_port4003-.{12}$"
    end

    test "a run named by TENANT or TEST_RUN uses that name" do
      put_run_tag("_pr_1234")

      assert Docker.container_prefix() == "realtime-test_pr_1234"
      assert Docker.own_container?("realtime-test_pr_1234-" <> @suffix)
    end
  end

  describe "own_container?/1" do
    test "ignores containers from another run" do
      put_run_tag("")

      assert Docker.own_container?("realtime-test-" <> @suffix)
      refute Docker.own_container?("realtime-test_port4003-" <> @suffix)
      refute Docker.own_container?("some-other-container")
    end
  end

  describe "abandoned_container?/1" do
    test "false while the owning run still holds its port" do
      refute Docker.abandoned_container?("realtime-test_port#{TestEnv.http_port()}-#{@suffix}")
    end

    test "true once that port is free" do
      assert Docker.abandoned_container?("realtime-test_port#{Env.unused_port()}-#{@suffix}")
    end

    test "false for an untagged container, which belongs to whoever holds the default port" do
      refute Docker.abandoned_container?("realtime-test-#{@suffix}")
    end

    test "false for a named run, whose tag says nothing about whether it is still going" do
      refute Docker.abandoned_container?("realtime-test_pr_1234-#{@suffix}")
    end

    test "false for a run named after digits, which is a name and not a port" do
      refute Docker.abandoned_container?("realtime-test_#{Env.unused_port()}-#{@suffix}")
    end

    test "false for a name that only reads like a tagged one" do
      refute Docker.abandoned_container?("realtime-test_port4003-tooshort")
      refute Docker.abandoned_container?("some-other-container")
    end
  end
end
