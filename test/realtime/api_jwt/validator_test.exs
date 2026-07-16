defmodule Realtime.ApiJwt.ValidatorTest do
  use ExUnit.Case, async: true

  alias Realtime.ApiJwt.Validator

  describe "parse/1" do
    test "parses a full validator" do
      json =
        Jason.encode!([
          %{
            "jwks_url" => "https://platform.example/jwks",
            "issuer" => "https://platform.example",
            "audience" => "realtime",
            "subject" => "platform-service"
          }
        ])

      assert {:ok,
              [
                %Validator{
                  jwks_url: "https://platform.example/jwks",
                  issuer: "https://platform.example",
                  audiences: ["realtime"],
                  subjects: ["platform-service"]
                }
              ]} = Validator.parse(json)
    end

    test "parses list-valued audience and subject" do
      json =
        Jason.encode!([
          %{"jwks_url" => "https://p/jwks", "issuer" => "https://p", "audience" => ["a", "b"], "subject" => ["s1", "s2"]}
        ])

      assert {:ok, [%Validator{audiences: ["a", "b"], subjects: ["s1", "s2"]}]} = Validator.parse(json)
    end

    test "parses multiple validators for rotation" do
      json =
        Jason.encode!([
          %{"jwks_url" => "https://p1/jwks", "issuer" => "https://p1", "audience" => "realtime", "subject" => "svc"},
          %{"jwks_url" => "https://p2/jwks", "issuer" => "https://p2", "audience" => "realtime", "subject" => "svc"}
        ])

      assert {:ok, [%Validator{issuer: "https://p1"}, %Validator{issuer: "https://p2"}]} = Validator.parse(json)
    end

    test "empty array is valid" do
      assert {:ok, []} = Validator.parse("[]")
    end

    test "rejects invalid JSON" do
      assert {:error, :invalid_json} = Validator.parse("not json")
    end

    test "rejects non-array" do
      assert {:error, :not_a_list} = Validator.parse(~s({"issuer": "x"}))
    end

    test "rejects missing required fields" do
      json = Jason.encode!([%{"issuer" => "https://p", "audience" => "realtime"}])
      assert {:error, :missing_required_fields} = Validator.parse(json)
    end

    test "rejects a missing subject" do
      json = Jason.encode!([%{"jwks_url" => "https://p/jwks", "issuer" => "https://p", "audience" => "a"}])
      assert {:error, :missing_required_fields} = Validator.parse(json)
    end

    test "ignores an unknown extra field" do
      json =
        Jason.encode!([
          %{
            "jwks_url" => "https://p/jwks",
            "issuer" => "https://p",
            "audience" => "a",
            "subject" => "svc",
            "algorithms" => ["HS256"]
          }
        ])

      assert {:ok, [%Validator{issuer: "https://p", audiences: ["a"], subjects: ["svc"]}]} = Validator.parse(json)
    end
  end
end
