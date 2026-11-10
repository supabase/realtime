defmodule SqlLogex.EnvTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Env

  describe "new/2" do
    test "stores the settings and the row" do
      env = Env.new(%{"role" => "guest"}, %{"team" => {:text, "t"}})

      assert %Env{settings: %{"role" => "guest"}, row: %{"team" => {:text, "t"}}} = env
    end

    test "lowercases setting names, ASCII only" do
      env = Env.new(%{"App.Claims" => "{}", "APP.TEAM" => "t", "café.X" => "v", "CAFÉ.x" => "w"}, %{})

      assert env.settings == %{"app.claims" => "{}", "app.team" => "t", "café.x" => "v", "cafÉ.x" => "w"}
    end

    test "keeps nil, which stands for a reset setting" do
      assert Env.new(%{"app.user_id" => nil}, %{}).settings == %{"app.user_id" => nil}
    end

    test "the settings and the row are required maps" do
      assert_raise FunctionClauseError, fn -> Env.new([], %{}) end
      assert_raise FunctionClauseError, fn -> Env.new(%{}, nil) end
    end
  end
end
