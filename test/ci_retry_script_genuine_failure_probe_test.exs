defmodule CiRetryScriptGenuineFailureProbeTest do
  use ExUnit.Case, async: true

  test "always fails on purpose" do
    assert false
  end
end
