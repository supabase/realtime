defmodule RealtimeWeb.Channels.Payloads.ChangesetNormalizerTest do
  use ExUnit.Case, async: true

  alias RealtimeWeb.Channels.Payloads.ChangesetNormalizer

  describe "normalize_boolean/1" do
    test "returns true for boolean true" do
      assert ChangesetNormalizer.normalize_boolean(true) == true
    end

    test "returns false for boolean false" do
      assert ChangesetNormalizer.normalize_boolean(false) == false
    end

    test "converts string 'true' in any case to boolean true" do
      assert ChangesetNormalizer.normalize_boolean("true") == true
      assert ChangesetNormalizer.normalize_boolean("True") == true
      assert ChangesetNormalizer.normalize_boolean("TRUE") == true
    end

    test "converts string 'false' in any case to boolean false" do
      assert ChangesetNormalizer.normalize_boolean("false") == false
      assert ChangesetNormalizer.normalize_boolean("False") == false
      assert ChangesetNormalizer.normalize_boolean("FALSE") == false
    end

    test "returns other string values as-is" do
      assert ChangesetNormalizer.normalize_boolean("test") == "test"
      assert ChangesetNormalizer.normalize_boolean(1) == 1
      assert ChangesetNormalizer.normalize_boolean(nil) == nil
      assert ChangesetNormalizer.normalize_boolean(%{}) == %{}
      assert ChangesetNormalizer.normalize_boolean([]) == []
    end
  end

  describe "normalize_boolean_fields/2" do
    test "normalizes boolean fields with string keys" do
      attrs = %{"enabled" => "true", "ack" => "false"}
      result = ChangesetNormalizer.normalize_boolean_fields(attrs, [:enabled, :ack])

      assert result == %{"enabled" => true, "ack" => false}
    end

    test "normalizes boolean fields with atom keys" do
      attrs = %{enabled: "True", ack: "False"}
      result = ChangesetNormalizer.normalize_boolean_fields(attrs, [:enabled, :ack])

      assert result == %{enabled: true, ack: false}
    end

    test "normalizes mixed string and atom keys" do
      attrs = %{"enabled" => "true", :ack => "false"}
      result = ChangesetNormalizer.normalize_boolean_fields(attrs, [:enabled, :ack])

      assert result == %{"enabled" => true, :ack => false}
    end

    test "leaves non-boolean fields unchanged" do
      attrs = %{"enabled" => "true", "name" => "test", "count" => 42}
      result = ChangesetNormalizer.normalize_boolean_fields(attrs, [:enabled])

      assert result == %{"enabled" => true, "name" => "test", "count" => 42}
    end

    test "leaves fields not in the list unchanged" do
      attrs = %{"enabled" => "true", "other" => "false"}
      result = ChangesetNormalizer.normalize_boolean_fields(attrs, [:enabled])

      assert result == %{"enabled" => true, "other" => "false"}
    end

    test "handles missing fields gracefully" do
      attrs = %{"name" => "test"}
      result = ChangesetNormalizer.normalize_boolean_fields(attrs, [:enabled, :ack])

      assert result == %{"name" => "test"}
    end

    test "handles actual boolean values without changing them" do
      attrs = %{"enabled" => true, "ack" => false}
      result = ChangesetNormalizer.normalize_boolean_fields(attrs, [:enabled, :ack])

      assert result == %{"enabled" => true, "ack" => false}
    end

    test "leaves invalid boolean strings as-is for validation to catch" do
      attrs = %{"enabled" => "invalid", "ack" => "test"}
      result = ChangesetNormalizer.normalize_boolean_fields(attrs, [:enabled, :ack])

      assert result == %{"enabled" => "invalid", "ack" => "test"}
    end

    test "returns non-map values as-is" do
      assert ChangesetNormalizer.normalize_boolean_fields("not a map", [:enabled]) == "not a map"
      assert ChangesetNormalizer.normalize_boolean_fields(nil, [:enabled]) == nil
      assert ChangesetNormalizer.normalize_boolean_fields([], [:enabled]) == []
    end

    test "handles empty field list" do
      attrs = %{"enabled" => "true"}
      result = ChangesetNormalizer.normalize_boolean_fields(attrs, [])

      assert result == %{"enabled" => "true"}
    end
  end
end
