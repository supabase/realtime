defmodule SqlLogex.EnvTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Env

  describe "new/2" do
    test "stores the settings and the row" do
      env = Env.new(%{"role" => "anon"}, %{"topic" => {:text, "t"}})

      assert %Env{settings: %{"role" => "anon"}, row: %{"topic" => {:text, "t"}}} = env
    end

    test "lowercases setting names, ASCII only" do
      env = Env.new(%{"Request.JWT.Claims" => "{}", "REALTIME.TOPIC" => "t", "café.X" => "v", "CAFÉ.x" => "w"}, %{})

      assert env.settings == %{"request.jwt.claims" => "{}", "realtime.topic" => "t", "café.x" => "v", "cafÉ.x" => "w"}
    end

    test "keeps nil, which stands for a reset setting" do
      assert Env.new(%{"request.jwt.claim.sub" => nil}, %{}).settings == %{"request.jwt.claim.sub" => nil}
    end

    test "the settings and the row are required maps" do
      assert_raise FunctionClauseError, fn -> Env.new([], %{}) end
      assert_raise FunctionClauseError, fn -> Env.new(%{}, nil) end
    end
  end
end
