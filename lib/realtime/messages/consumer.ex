defmodule Realtime.Messages.Consumer do
  @moduledoc """
  The consumer stage of the pipeline that persists messages, see "Persistence" in `Realtime.Messages`.
  Each event is a batch, written with `Realtime.Messages.insert_batch/5`, and it sends each result to its
  `:reply_to`. It is the only process that writes, so it keeps the last `inserted_at` it wrote.

  It subscribes to `Realtime.Messages.Producer` in `:manual` mode, and asks for one event with
  `GenStage.ask/3` once it wrote the previous one, as described in "Asynchronous work and
  `handle_subscribe`" in `GenStage`. After `:breaker_threshold` failed batches in a row, it waits
  `:breaker_cooldown_ms` before it asks again, and the producer buffers messages meanwhile.
  """
  use GenStage
  use Realtime.Logs

  alias Realtime.Messages

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    config = Keyword.fetch!(opts, :config)
    hibernate_after = Keyword.fetch!(config, :hibernate_after)
    GenStage.start_link(__MODULE__, opts, hibernate_after: hibernate_after)
  end

  @impl true
  def init(opts) do
    db_conn = Keyword.fetch!(opts, :db_conn)
    tenant_id = Keyword.fetch!(opts, :tenant_id)
    producer = Keyword.fetch!(opts, :producer)
    config = Keyword.fetch!(opts, :config)
    Logger.metadata(external_id: tenant_id, project: tenant_id)

    state = %{
      db_conn: db_conn,
      tenant_id: tenant_id,
      producer: producer,
      config: config,
      failures: 0,
      last_inserted_at: nil
    }

    {:consumer, state, subscribe_to: [producer]}
  end

  @impl true
  def handle_subscribe(:producer, _opts, from, state) do
    GenStage.ask(from, 1)
    {:manual, state}
  end

  @impl true
  def handle_events([batch], from, state) do
    state = write(batch, state)
    ask(from, state)
    {:noreply, [], state}
  end

  @impl true
  def handle_info({:ask, from}, state) do
    GenStage.ask(from, 1)
    {:noreply, [], state}
  end

  @impl true
  def handle_call({:stop, batches}, _from, state) do
    {:stop, :normal, :ok, Enum.reduce(batches, state, &write/2)}
  end

  defp write(batch, state) do
    {result, replies, last_inserted_at} = insert(batch, state)
    Messages.reply(replies)
    for {reason, count} <- errors(replies), do: send(state.producer, {:dropped, reason, count})
    %{state | last_inserted_at: last_inserted_at, failures: count_failures(state.failures, result)}
  end

  # Failures are not reset by the pause, so a write that fails after it pauses again
  defp count_failures(_failures, :ok), do: 0
  defp count_failures(failures, :error), do: failures + 1

  defp ask(from, %{failures: failures, config: config}) do
    breaker_threshold = Keyword.fetch!(config, :breaker_threshold)
    breaker_cooldown_ms = Keyword.fetch!(config, :breaker_cooldown_ms)

    if failures >= breaker_threshold do
      writes = if failures == 1, do: "1 failed write", else: "#{failures} failed writes"
      log_error("PersistenceUnavailable", "Persistence paused after #{writes}")
      Process.send_after(self(), {:ask, from}, breaker_cooldown_ms)
    else
      GenStage.ask(from, 1)
    end
  end

  defp insert(batch, state) do
    {entries, callers} = Enum.unzip(batch)
    timeout = Keyword.fetch!(state.config, :query_timeout)

    case Messages.insert_batch(state.db_conn, state.tenant_id, entries, state.last_inserted_at, timeout) do
      {:ok, results, last_inserted_at} -> {:ok, Enum.zip(callers, results), last_inserted_at}
      {:error, reason} -> {:error, fail(batch, reason), state.last_inserted_at}
    end
  end

  defp fail(batch, reason) do
    Enum.map(batch, fn {_entry, caller} -> {caller, {:error, reason}} end)
  end

  defp errors(replies) do
    Enum.frequencies(for {_caller, {:error, reason}} <- replies, do: reason)
  end
end
