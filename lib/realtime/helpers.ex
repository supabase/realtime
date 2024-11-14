defmodule Realtime.Helpers do
  @moduledoc """
  This module includes helper functions for different contexts that can't be union in one module.
  """
  require Logger

  @spec cancel_timer(reference() | nil) :: non_neg_integer() | false | :ok | nil
  def cancel_timer(nil), do: nil
  def cancel_timer(ref), do: Process.cancel_timer(ref)

  @doc """
  Takes the first N items from the queue and returns the list of items and the new queue.

  ## Examples

      iex> q = :queue.new()
      iex> q = :queue.in(1, q)
      iex> q = :queue.in(2, q)
      iex> q = :queue.in(3, q)
      iex> Realtime.Helpers.queue_take(q, 2)
      {[2, 1], {[], [3]}}
  """

  @spec queue_take(:queue.queue(), non_neg_integer()) :: {list(), :queue.queue()}
  def queue_take(q, count) do
    Enum.reduce_while(1..count, {[], q}, fn _, {items, queue} ->
      case :queue.out(queue) do
        {{:value, item}, new_q} ->
          {:cont, {[item | items], new_q}}

        {:empty, new_q} ->
          {:halt, {items, new_q}}
      end
    end)
  end
end
