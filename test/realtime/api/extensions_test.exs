defmodule Realtime.Api.ExtensionsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Realtime.Api.Extensions

  describe "changeset/2 with nil type" do
    test "skips default settings merge" do
      changeset = Extensions.changeset(%Extensions{}, %{"settings" => %{"foo" => "bar"}})
      assert changeset.changes[:settings] == %{"foo" => "bar"}
    end

    test "validates required fields" do
      changeset = Extensions.changeset(%Extensions{}, %{})
      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:type]
      assert {"can't be blank", _} = changeset.errors[:settings]
    end
  end

  describe "changeset/2 with type" do
    test "merges default settings for postgres_cdc_rls" do
      attrs = %{
        "type" => "postgres_cdc_rls",
        "settings" => %{
          "region" => "us-east-1",
          "db_host" => "localhost",
          "db_name" => "postgres",
          "db_user" => "user",
          "db_port" => "5432",
          "db_password" => "pass"
        }
      }

      changeset = Extensions.changeset(%Extensions{}, attrs)
      settings = changeset.changes[:settings]

      assert settings["publication"] == "supabase_realtime"
      assert settings["slot_name"] == "supabase_realtime_replication_slot"
      assert settings["region"] == "us-east-1"
    end
  end

  describe "validate_required_settings/2" do
    test "adds error when required field is nil" do
      required = [{"db_host", &is_binary/1, false}]

      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test", settings: %{}}, [:type, :settings])
        |> Extensions.validate_required_settings(required)

      refute changeset.valid?
      assert {"db_host can't be blank", []} = changeset.errors[:settings]
    end

    test "adds error when checker function fails" do
      required = [{"db_port", &is_binary/1, false}]

      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test", settings: %{"db_port" => 5432}}, [:type, :settings])
        |> Extensions.validate_required_settings(required)

      refute changeset.valid?
      assert {"db_port is invalid", []} = changeset.errors[:settings]
    end

    test "passes when all required fields are valid" do
      required = [{"db_host", &is_binary/1, false}]

      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test", settings: %{"db_host" => "localhost"}}, [:type, :settings])
        |> Extensions.validate_required_settings(required)

      assert changeset.valid?
    end
  end

  describe "encrypt_settings/2" do
    test "encrypts fields marked for encryption" do
      required = [{"db_password", &is_binary/1, true}]

      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test", settings: %{"db_password" => "secret"}}, [:type, :settings])
        |> Extensions.encrypt_settings(required)

      settings = Ecto.Changeset.get_change(changeset, :settings)
      assert settings["db_password"] != "secret"
      assert Realtime.Crypto.decrypt!(settings["db_password"]) == "secret"
    end

    test "does not modify fields not marked for encryption" do
      required = [{"region", &is_binary/1, false}]

      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test", settings: %{"region" => "us-east-1"}}, [:type, :settings])
        |> Extensions.encrypt_settings(required)

      settings = Ecto.Changeset.get_change(changeset, :settings)
      assert settings["region"] == "us-east-1"
    end
  end

  defp ai_agent_attrs(settings) do
    base = %{
      "protocol" => "anthropic",
      "base_url" => "https://api.example.com",
      "api_key" => "key",
      "model" => "claude-3-5-sonnet-latest"
    }

    %{"type" => "ai_agent", "name" => "my_agent", "settings" => Map.merge(base, settings)}
  end

  describe "changeset/2 for ai_agent type" do
    test "requires name" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)

      attrs = %{
        "type" => "ai_agent",
        "settings" => %{"base_url" => "https://api.example.com", "api_key" => "key", "model" => "m"}
      }

      changeset = Extensions.changeset(%Extensions{}, attrs)
      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:name]
    end

    test "valid with https base_url resolving to public IP" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{}))
      assert changeset.valid?
    end

    test "rejects base_url resolving to private IP (10.x.x.x)" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{10, 0, 0, 1}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{}))
      refute changeset.valid?
      assert {"base_url resolves to a private or reserved address", _} = changeset.errors[:settings]
    end

    test "rejects base_url resolving to private IP (192.168.x.x)" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{192, 168, 1, 1}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{}))
      refute changeset.valid?
      assert {"base_url resolves to a private or reserved address", _} = changeset.errors[:settings]
    end

    test "rejects base_url when host cannot be resolved" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:error, :nxdomain} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{}))
      refute changeset.valid?
      assert {"base_url host cannot be resolved", _} = changeset.errors[:settings]
    end

    test "allows http base_url for localhost" do
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"base_url" => "http://localhost:4000"}))
      assert changeset.valid?
    end

    test "allows http base_url for 127.0.0.1" do
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"base_url" => "http://127.0.0.1:4000"}))
      assert changeset.valid?
    end

    test "rejects http base_url for non-loopback host" do
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"base_url" => "http://api.example.com"}))
      refute changeset.valid?

      assert {"base_url with http scheme is only permitted for loopback hosts (localhost, 127.0.0.1)", _} =
               changeset.errors[:settings]
    end

    test "rejects base_url with no scheme" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"base_url" => "api.example.com"}))
      refute changeset.valid?
      assert {"base_url must use https scheme", _} = changeset.errors[:settings]
    end

    test "rejects base_url that is not a string" do
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"base_url" => 1234}))
      refute changeset.valid?
    end

    test "rejects nil base_url as blank" do
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"base_url" => nil}))
      refute changeset.valid?
      assert {"base_url can't be blank", _} = changeset.errors[:settings]
    end

    test "rejects http_referer containing newline" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)

      changeset =
        Extensions.changeset(
          %Extensions{},
          ai_agent_attrs(%{"http_referer" => "https://evil.com\r\nX-Injected: header"})
        )

      refute changeset.valid?
      assert {"http_referer contains invalid characters", _} = changeset.errors[:settings]
    end

    test "rejects x_title containing carriage return" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"x_title" => "title\rinjected"}))
      refute changeset.valid?
      assert {"x_title contains invalid characters", _} = changeset.errors[:settings]
    end

    test "rejects http_referer that is not a string" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"http_referer" => 123}))
      refute changeset.valid?
      assert {"http_referer must be a string", _} = changeset.errors[:settings]
    end

    test "accepts string system_prompt" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"system_prompt" => "You are helpful."}))
      assert changeset.valid?
    end

    test "accepts nil system_prompt" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"system_prompt" => nil}))
      assert changeset.valid?
    end

    test "accepts absent system_prompt" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{}))
      assert changeset.valid?
    end

    test "rejects non-string system_prompt" do
      stub(Realtime.DNS, :getaddrs, fn _host, :inet, _timeout -> {:ok, [{1, 2, 3, 4}]} end)
      changeset = Extensions.changeset(%Extensions{}, ai_agent_attrs(%{"system_prompt" => 123}))
      refute changeset.valid?
      assert {"system_prompt must be a string", _} = changeset.errors[:settings]
    end
  end
end
