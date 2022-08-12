defmodule Realtime.GenCounter do
  @moduledoc """
  A generic counter interface for any Erlang term. One counter per term.
  Counters are registered locally via the Registry so we can look them up by term.

  GenServers are used to keep counters alive across callers, however calls to the
  counters are not serialized through the GenServer keeping GenCounters as performant as possible.
  """
  use GenServer

  alias Realtime.GenCounter

  require Logger

  defstruct id: nil, counters: []

  @type t :: %__MODULE__{
          id: term(),
          counters: list()
        }

  def start_link(args) do
    id = Keyword.get(args, :id)
    unless id, do: raise("Supply an identifier to start a counter!")

    GenServer.start_link(__MODULE__, args,
      name: {:via, Registry, {Realtime.Registry.Unique, {__MODULE__, :worker, id}}}
    )
  end

  @doc """
  Creates a new counter from any Erlang term.
  """
  @spec new(term) :: {:ok, {:write_concurrency, reference()}} | {:error, term()}
  def new(term) do
    id = :erlang.phash2(term)

    worker =
      DynamicSupervisor.start_child(GenCounter.DynamicSupervisor, %{
        id: id,
        start: {__MODULE__, :start_link, [[id: id]]},
        restart: :transient
      })

    with {:ok, pid} <- worker,
         {:ok, ref} <- GenServer.call(pid, :new) do
      {:ok, ref}
    else
      {:error, {:already_started, _}} = started ->
        started

      err ->
        Logger.error("Error creating counter #{inspect(err)}")
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

  @spec stop(term()) :: :ok | {:error, :not_found | :counter_not_found}
  def stop(term) do
    case find_worker(term) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(GenCounter.DynamicSupervisor, pid)
      error -> error
    end
  end

  # Callbacks

  @impl true
  def init(args) do
    id = Keyword.get(args, :id)

    state = %__MODULE__{id: id, counters: []}

    {:ok, state}
  end

  @impl true
  def handle_call(:new, _from, state) do
    ref = :counters.new(1, [:write_concurrency])

    {:ok, _} = Registry.register(Realtime.Registry.Unique, {__MODULE__, :counter, state.id}, ref)

    counters = [ref, state.counters]

    {:reply, {:ok, ref}, %{state | counters: counters}}
  end

  defp find_worker(term) do
    id = :erlang.phash2(term)

    case Registry.lookup(Realtime.Registry.Unique, {__MODULE__, :worker, id}) do
      [{pid, _}] -> {:ok, pid}
      _error -> {:error, :worker_not_found}
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
