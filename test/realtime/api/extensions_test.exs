defmodule Realtime.Api.ExtensionsTest do
  use ExUnit.Case, async: true

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
    test "encrypts fields flagged for encryption" do
      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test", settings: %{"db_password" => "secret"}}, [:type, :settings])
        |> Extensions.encrypt_settings([{"db_password", &is_binary/1, true}])

      settings = Ecto.Changeset.get_change(changeset, :settings)
      assert settings["db_password"] != "secret"
      assert Realtime.Crypto.decrypt!(settings["db_password"]) == "secret"
    end

    test "dual-writes settings_gcm alongside the legacy settings column" do
      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test", settings: %{"db_password" => "secret"}}, [:type, :settings])
        |> Extensions.encrypt_settings([{"db_password", &is_binary/1, true}])

      settings = Ecto.Changeset.get_change(changeset, :settings)
      settings_gcm = Ecto.Changeset.get_change(changeset, :settings_gcm)

      refute settings_gcm["db_password"] == settings["db_password"]
      assert Realtime.Crypto.decrypt_gcm!(settings_gcm["db_password"]) == "secret"
    end

    test "leaves fields not flagged for encryption untouched" do
      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test", settings: %{"region" => "us-east-1"}}, [:type, :settings])
        |> Extensions.encrypt_settings([{"region", &is_binary/1, false}])

      settings = Ecto.Changeset.get_change(changeset, :settings)
      settings_gcm = Ecto.Changeset.get_change(changeset, :settings_gcm)
      assert settings["region"] == "us-east-1"
      assert settings_gcm["region"] == "us-east-1"
    end

    test "skips flagged fields that are absent" do
      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test", settings: %{"db_host" => "localhost"}}, [:type, :settings])
        |> Extensions.encrypt_settings([{"db_password", &is_binary/1, true}])

      settings = Ecto.Changeset.get_change(changeset, :settings)
      settings_gcm = Ecto.Changeset.get_change(changeset, :settings_gcm)
      refute Map.has_key?(settings, "db_password")
      refute Map.has_key?(settings_gcm, "db_password")
    end

    test "leaves settings_gcm unset when there is no settings change" do
      changeset =
        %Extensions{}
        |> Ecto.Changeset.cast(%{type: "test"}, [:type, :settings])
        |> Extensions.encrypt_settings([{"db_password", &is_binary/1, true}])

      refute Ecto.Changeset.get_change(changeset, :settings_gcm)
    end
  end

  describe "reconcile_encryption_changeset/2" do
    test "only accepts and requires settings_gcm" do
      changeset =
        Extensions.reconcile_encryption_changeset(%Extensions{}, %{
          settings_gcm: %{"db_password" => "ciphertext"},
          type: "should be ignored"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :settings_gcm) == %{"db_password" => "ciphertext"}
      refute Ecto.Changeset.get_change(changeset, :type)

      refute Extensions.reconcile_encryption_changeset(%Extensions{}, %{}).valid?
    end
  end
end
