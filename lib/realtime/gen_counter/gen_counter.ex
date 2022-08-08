defmodule Realtime.GenCounter do
  @moduledoc """
  A generic counter interface for any Erlang term. One counter per term.
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

  @spec new(term) :: {:ok, {:write_concurrency, reference()}} | {:error, :not_found}
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
      err ->
        Logger.error("Error creating counter", error_string: inspect(err))
        {:error, :not_found}
    end
  end

  @spec add(term()) :: :ok | :error
  def add(term) do
    add(term, 1)
  end

  @spec add(term(), integer()) :: :ok | :error
  def add(term, count) when is_integer(count) do
    with {:ok, pid} <- find_worker(term),
         {:ok, index} <- find_index(pid),
         {:ok, counter_ref} <- find_counter(term) do
      :counters.add(counter_ref, index, count)
    else
      err ->
        Logger.error("Error incrimenting counter", error_string: inspect(err))
        :error
    end
  end

  @spec sub(term()) :: :ok | :error
  def sub(term) do
    sub(term, 1)
  end

  @spec sub(term(), integer()) :: :ok | :error
  def sub(term, count) when is_integer(count) do
    with {:ok, pid} <- find_worker(term),
         {:ok, index} <- find_index(pid),
         {:ok, counter_ref} <- find_counter(term) do
      :counters.sub(counter_ref, index, count)
    else
      err ->
        Logger.error("Error decrimenting counter", error_string: inspect(err))
        :error
    end
  end

  @spec put(term(), integer()) :: :ok | :error
  def put(term, count) when is_integer(count) do
    with {:ok, pid} <- find_worker(term),
         {:ok, index} <- find_index(pid),
         {:ok, counter_ref} <- find_counter(term) do
      :counters.put(counter_ref, index, count)
    else
      err ->
        Logger.error("Error updating counter", error_string: inspect(err))
        :error
    end
  end

  @spec info(term()) :: :ok | :error
  def info(term) do
    with {:ok, counter_ref} <-
           find_counter(term) do
      :counters.info(counter_ref)
    else
      err ->
        Logger.error("Error", error_string: inspect(err))
        :error
    end
  end

  @spec get(term()) ::
          {:ok, integer()} | {:error, :child_not_found | :worker_not_found | :counter_not_found}
  def get(term) do
    with {:ok, pid} <- find_worker(term),
         {:ok, index} <- find_index(pid),
         {:ok, counter_ref} <- find_counter(term) do
      count = :counters.get(counter_ref, index)
      {:ok, count}
    else
      err ->
        Logger.error("Counter not found", error_string: inspect(err))
        err
    end
  end

  # Callbacks

  @impl true
  def init(args) do
    id = Keyword.get(args, :id)
    # tenant = Realtime.Api.get_tenant_by_external_id(tenant)

    # unless tenant, do: raise("Tenant not found in database!")

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

  defp find_index(_pid) do
    {:ok, 1}
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
