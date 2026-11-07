defmodule Rollcall.Tracker.MessagesTest do
  use ExUnit.Case, async: true

  import Rollcall.Tracker.Messages, only: [diff: 5, request: 1, snapshot: 3, stamp: 2, wire_entry: 4]

  alias Rollcall.Tracker.Messages

  describe "message?/1" do
    test "is true for each kind of message" do
      origin = self()
      entries = [wire_entry("partition", "key", "ref", %{})]

      assert Messages.message?(snapshot(origin, stamp(1, 3), entries))
      assert Messages.message?(diff(origin, stamp(1, 4), 3, entries, ["ref"]))
      assert Messages.message?(request(origin))
    end

    # Each term breaks one check. The description names the check, and the
    # failure message of `refute/2` shows it.
    test "is false for a term that breaks a check" do
      origin = self()

      malformed = [
        {"a term that is not a tuple", :not_a_message},
        {"a tuple with an unknown kind", {:unknown, origin}},
        {"a request with an extra element", {:request, origin, :extra}},
        {"a snapshot with a missing element", {:snapshot, origin, stamp(1, 3)}},
        {"a diff with a missing element", {:diff, origin, stamp(1, 4), 3, []}},
        {"an origin that is not a pid", {:request, :not_a_pid}},
        {"a stamp that is not a stamp tuple", {:snapshot, origin, {1, 3}, []}},
        {"a stamp whose incarnation is not an integer", {:snapshot, origin, {:stamp, :not_an_integer, 3}, []}},
        {"a stamp whose version is not an integer", {:snapshot, origin, {:stamp, 1, :not_an_integer}, []}},
        {"a snapshot whose entries are not a list", {:snapshot, origin, stamp(1, 3), :not_a_list}},
        {"a diff whose joins are not a list", {:diff, origin, stamp(1, 4), 3, :not_a_list, []}},
        {"a diff whose leaves are not a list", {:diff, origin, stamp(1, 4), 3, [], :not_a_list}}
      ]

      for {description, term} <- malformed do
        refute Messages.message?(term), "expected false for #{description}"
      end
    end
  end
end
