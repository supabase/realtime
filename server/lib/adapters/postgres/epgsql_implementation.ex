# This file draws heavily from https://github.com/cainophile/cainophile
# License: https://github.com/cainophile/cainophile/blob/master/LICENSE

defmodule Realtime.Adapters.Postgres.EpgsqlImplementation do
  @behaviour Realtime.Adapters.Postgres.AdapterBehaviour
  require Logger

  alias Realtime.Adapters.ConnRetry

  @impl true
  def init(config) do
    epgsql_config =
      Keyword.get(config, :epgsql, %{})
      |> Map.put(:replication, "database")

    {xlog, offset} = Keyword.get(config, :wal_position, {"0", "0"})

    publication_names =
      Keyword.get(config, :publications)
      |> Enum.map(fn pub -> ~s("#{pub}") end)
      |> Enum.join(",")

    with {:ok, epgsql_pid} <- :epgsql.connect(epgsql_config),
         :ok <- maybe_drop_replication_slots(epgsql_pid),
         true <- does_publication_exist(epgsql_pid, publication_names),
         {:ok, slot_name} <-
           maybe_create_replication_slot(epgsql_pid, Keyword.get(config, :slot, :temporary)),
         :ok <-
           :epgsql.start_replication(
             epgsql_pid,
             slot_name,
             self(),
             [],
             '#{xlog}/#{offset}',
             'proto_version \'1\', publication_names \'#{publication_names}\''
           ) do
      {:ok, epgsql_pid}
    else
      reason ->
        {:error, reason}
    end
  end

  @impl true
  def acknowledge_lsn(epgsql, {_xlog, _offset} = lsn_tup) do
    decimal_lsn = lsn_tuple_to_decimal(lsn_tup)

    :epgsql.standby_status_update(epgsql, decimal_lsn, decimal_lsn)
  end

  defp lsn_tuple_to_decimal({xlog, offset}) do
    <<decimal_lsn::integer-64>> = <<xlog::integer-32, offset::integer-32>>
    decimal_lsn
  end

  defp maybe_drop_replication_slots(epgsql_pid) do
    if ConnRetry.get_drop_replication_slots() do
      case :epgsql.squery(epgsql_pid, "SELECT slot_name FROM pg_replication_slots") do
        {:ok, _, slot_names} ->
          :ok =
            Enum.each(slot_names, fn {slot_name} ->
              :epgsql.squery(epgsql_pid, "DROP_REPLICATION_SLOT " <> slot_name)
            end)

          :ok = ConnRetry.set_drop_replication_slots(false)

        {:error, reason} ->
          reason
      end
    else
      :ok
    end
  end

  defp does_publication_exist(epgsql_pid, publication_names) do
    case :epgsql.squery(
           epgsql_pid,
           "SELECT COUNT(*) = 1 FROM pg_publication WHERE pubname = '#{
             String.replace(publication_names, "\"", "")
           }'"
         ) do
      {:ok, _, [{existing_slot}]} ->
        case existing_slot do
          "t" -> true
          "f" -> "publication #{publication_names} does not exist"
        end

      {:error, reason} ->
        reason
    end
  end

  defp maybe_create_replication_slot(epgsql_pid, slot) do
    {slot_name, start_replication_command} =
      case slot do
        name when is_binary(name) ->
          # Simple query for replication mode so no prepared statements are supported
          escaped_name = String.downcase(String.replace(name, "'", "\\'"))

          query =
            "SELECT COUNT(*) >= 1 FROM pg_replication_slots WHERE slot_name = '#{escaped_name}'"

          {:ok, _, [{existing_slot}]} = :epgsql.squery(epgsql_pid, query)

          case existing_slot do
            "t" ->
              # no-op
              {name, "SELECT 1"}

            "f" ->
              {name, "CREATE_REPLICATION_SLOT #{escaped_name} LOGICAL pgoutput NOEXPORT_SNAPSHOT"}
          end

        :temporary ->
          slot_name = self_as_slot_name()

          {slot_name,
           "CREATE_REPLICATION_SLOT #{slot_name} TEMPORARY LOGICAL pgoutput NOEXPORT_SNAPSHOT"}
      end

    case :epgsql.squery(epgsql_pid, start_replication_command) do
      {:ok, _, _} ->
        {:ok, slot_name}

      {:error, epgsql_error} ->
        {:error, epgsql_error}
    end
  end

  # TODO: Replace with better slot name generator
  defp self_as_slot_name() do
    "#PID<" <> pid = inspect(self())

    pid_number =
      String.replace(pid, ".", "_")
      |> String.slice(0..-2)

    "pid" <> pid_number
  end
end
