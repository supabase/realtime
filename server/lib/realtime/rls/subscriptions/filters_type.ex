defmodule Realtime.RLS.Subscriptions.Subscription.Filters do
  use Ecto.Type

  def type, do: :array

  def cast([] = filters), do: {:ok, filters}

  def cast([_, _, _] = filters) do
    {:ok, [List.to_tuple(filters)]}
  end

  def cast([{_, _, _}] = filters) do
    {:ok, filters}
  end

  def cast(_), do: :error

  def load(_), do: :error

  def dump(filters), do: cast(filters)
end
