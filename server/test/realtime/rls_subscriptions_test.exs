defmodule Realtime.RlsSubscriptionsTest do
  use ExUnit.Case

  setup_all do
    start_supervised(Realtime.RLS.Repo)
    :ok
  end
end
