defmodule Realtime.GenCounter do
  @moduledoc """
  A generic counter interface for any Erlang term. One counter per term.
  Counters are registered locally via the Registry so we can look them up by term.

  In the future we'd like to support groups of counters utilizing a single counter and multiple indexes.
  """

  require Logger

  @doc """
  Creates a new counter from any Erlang term.
  """
  @spec new(term) :: {:ok, {:write_concurrency, reference()}} | {:error, :not_created}
  def new(term) do
    with id <- :erlang.phash2(term),
         ref <- :counters.new(1, [:write_concurrency]),
         {:ok, _} <- Registry.register(Realtime.Registry.Unique, {__MODULE__, :counter, id}, ref) do
      {:ok, ref}
    else
      err ->
        Logger.error("Error creating counter", error_string: inspect(err))
        {:error, :not_created}
    end
  end

  @doc """
  Incriments a counter by one.
  """

  @spec add(term()) :: :ok | :error
  def add(term) do
    add(term, 1)
  end

  @doc """
  Incriments a counter by `count`.
  """

  @spec add(term(), integer()) :: :ok | :error
  def add(term, count) when is_integer(count) do
    with {:ok, counter_ref} <- find_counter(term) do
      :counters.add(counter_ref, 1, count)
    else
      err ->
        Logger.error("Error incrimenting counter", error_string: inspect(err))
        :error
    end
  end

  @doc """
  Decriments a counter by one.
  """

  @spec sub(term()) :: :ok | :error
  def sub(term) do
    sub(term, 1)
  end

  @doc """
  Decriments a counter by `count`.
  """

  @spec sub(term(), integer()) :: :ok | :error
  def sub(term, count) when is_integer(count) do
    with {:ok, counter_ref} <- find_counter(term) do
      :counters.sub(counter_ref, 1, count)
    else
      err ->
        Logger.error("Error decrimenting counter", error_string: inspect(err))
        :error
    end
  end

  @doc """
  Replaces a counter with `count`.
  """

  @spec put(term(), integer()) :: :ok | :error
  def put(term, count) when is_integer(count) do
    with {:ok, counter_ref} <- find_counter(term) do
      :counters.put(counter_ref, 1, count)
    else
      err ->
        Logger.error("Error updating counter", error_string: inspect(err))
        :error
    end
  end

  @doc """
  Gets info on a counter.
  """

  @spec info(term()) :: %{memory: integer(), size: integer()} | :error
  def info(term) do
    case find_counter(term) do
      {:ok, counter_ref} ->
        :counters.info(counter_ref)

      err ->
        Logger.error("Counter not found", error_string: inspect(err))
        :error
    end
  end

  @doc """
  Gets the count of a counter.
  """

  @spec get(term()) ::
          {:ok, integer()} | {:error, :counter_not_found}
  def get(term) do
    with {:ok, counter_ref} <- find_counter(term) do
      count = :counters.get(counter_ref, 1)
      {:ok, count}
    else
      err ->
        Logger.error("Counter not found", error_string: inspect(err))
        err
    end
  end

  defp find_counter(term) do
    id = :erlang.phash2(term)

    case Registry.lookup(Realtime.Registry.Unique, {__MODULE__, :counter, id}) do
      [{_pid, counter_ref}] -> {:ok, counter_ref}
      _error -> {:error, :counter_not_found}
    end
  end
end
