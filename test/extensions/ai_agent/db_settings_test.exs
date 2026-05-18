defmodule Extensions.AiAgent.DbSettingsTest do
  use ExUnit.Case, async: true

  alias Extensions.AiAgent.DbSettings

  describe "default/0" do
    test "fills max_concurrent_sessions when absent from settings" do
      default = DbSettings.default()
      assert default["max_concurrent_sessions"] == 10
    end
  end

  describe "required/0" do
    test "api_key is required and will be encrypted" do
      required = DbSettings.required()
      assert {"api_key", _, true} = List.keyfind!(required, "api_key", 0)
    end

    test "model, protocol, and base_url are required but not encrypted" do
      required = DbSettings.required()
      assert {"model", _, false} = List.keyfind!(required, "model", 0)
      assert {"protocol", _, false} = List.keyfind!(required, "protocol", 0)
      assert {"base_url", _, false} = List.keyfind!(required, "base_url", 0)
    end

    test "validators accept binary values" do
      for {_name, validator, _flag} <- DbSettings.required() do
        assert validator.("value") == true
      end
    end

    test "validators reject non-binary values" do
      for {_name, validator, _flag} <- DbSettings.required() do
        assert validator.(123) == false
      end
    end
  end
end
