defmodule RealtimeFilterParserTest do
  use ExUnit.Case, async: true

  alias RealtimeFilterParser

  test "parses complex filter string" do
    input =
      ~s/date=eq.2026-02-03,published_at=not.is.null,area=eq.Oslo\\, Norway,id=in.(1,2,3)/

    assert {:ok,
            [
              {"date", "eq", "2026-02-03"},
              {"published_at", "notnull", nil},
              {"area", "eq", "Oslo, Norway"},
              {"id", "in", "{1,2,3}"}
            ]} = RealtimeFilterParser.parse_filter(input)
  end

  test "parses in(...) into { ... }" do
    assert {:ok, [{"id", "in", "{1,2}"}]} = RealtimeFilterParser.parse_filter("id=in.(1,2)")
  end

  test "returns error for in without parentheses" do
    # malformed: value not wrapped in parentheses -> should error
    assert {:error, _} = RealtimeFilterParser.parse_filter("id=in.1,2,3")
  end

  test "empty or nil filter returns ok with empty list" do
    assert {:ok, []} = RealtimeFilterParser.parse_filter("")
    assert {:ok, []} = RealtimeFilterParser.parse_filter(nil)
  end
end
