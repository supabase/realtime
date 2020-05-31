defmodule Realtime.TransactionFilterTest do
  use ExUnit.Case

  alias Realtime.TransactionFilter.Filter
  alias Realtime.Adapters.Changes.Transaction
  doctest Realtime.TransactionFilter, import: true
end
