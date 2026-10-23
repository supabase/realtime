defmodule Realtime.Tenants.SqlLogexShadow do
  @moduledoc """
  Shadow-mode comparison: runs `SqlLogex.decide/3` alongside the real RLS check in
  `Realtime.Tenants.Authorization` and records whether it would have agreed. Never affects the real
  check's result and never raises into its caller — everything here runs in a detached `Task`, gated
  by the `"sql_logex_shadow"` feature flag.

  Three kinds of telemetry, per operation (`[:realtime, :tenants, :sql_logex, :shadow, :read | :write,
  ...]`):

    * the bare event, one per extension decided: metadata carries `outcome` (`:match`, `:mismatch`,
      `:fallback` or `:no_real_answer`), `real`, what the real check produced for that extension, and
      `reason`: for a `:fallback`, the bounded category of why
      (`SqlLogex.Reason.category/1`), `:none` for every other outcome. A `:mismatch` also logs a warning
      immediately. `:exception` is the same, for the rare case deciding itself raises.

      `real` is a boolean, or `{:error, sqlstate}` when Postgres raised evaluating the policies for
      this input, like a sub that isn't a uuid. That is Postgres's answer too, so a decided
      `:allow`/`:deny` against it is a `:mismatch`. `real` is `nil`, and the outcome
      `:no_real_answer`, only when the check couldn't run: no connection, a timeout, a missing
      partition, or any other error.
    * `:unavailable`, when the tenant's snapshot couldn't be loaded at all.
    * `:timing`, once per call: `shadow_duration`, the whole shadow pipeline (cache fetch included), in
      native time units. Compare against the real check's own cost via the existing
      `[:realtime, :tenants, :read_authorization_check]`/`:write_authorization_check` metrics
      (emitted from `authorization.ex`'s `read_policies_with_function/4`,
      `read_policies_with_transaction/4` and their write counterparts) rather than duplicating that
      measurement here — in the normal (non-fallback) case they already measure the real check's full
      cost.
  """
  use Realtime.Logs

  alias Realtime.FeatureFlags
  alias Realtime.Telemetry
  alias Realtime.Tenants.Authorization
  alias Realtime.Tenants.Authorization.Policies
  alias Realtime.Tenants.SqlLogexCache
  alias Realtime.Tenants.SqlLogexEnv

  @flag "sql_logex_shadow"
  @read_event [:realtime, :tenants, :sql_logex, :shadow, :read]
  @write_event [:realtime, :tenants, :sql_logex, :shadow, :write]

  # What stays the same across every extension of one read or write call: everything compare/3 needs
  # except the snapshot (not fetched yet when this is built) and the extension/real pair (per call).
  defmodule Check do
    @moduledoc false
    @type t :: %__MODULE__{authorization_context: Authorization.t(), event: [atom()], operation: :read | :write}
    defstruct [:authorization_context, :event, :operation]
  end

  @doc "Shadow-checks every extension a read checked."
  @spec read(DBConnection.conn(), Authorization.t(), [Authorization.extension()], term()) :: :ok
  def read(db_conn, authorization_context, extensions, result) do
    check = %Check{authorization_context: authorization_context, event: @read_event, operation: :read}
    pairs = Enum.map(extensions, &{&1, real_read(result, &1)})
    run(db_conn, check, pairs)
  end

  @doc """
  Shadow-checks every extension a write checked. In practice `Authorization.get_write_authorizations/4`
  only ever checks one, but this takes a list anyway, for the same shape as `read/4`.
  """
  @spec write(DBConnection.conn(), Authorization.t(), [Authorization.extension()], term()) :: :ok
  def write(db_conn, authorization_context, extensions, result) do
    check = %Check{authorization_context: authorization_context, event: @write_event, operation: :write}
    pairs = Enum.map(extensions, &{&1, real_write(result, &1)})
    run(db_conn, check, pairs)
  end

  # Feature-flag gate, then off the caller's back entirely: fetch the snapshot once, compare every
  # {extension, real} pair against it, time the whole thing.
  defp run(db_conn, %Check{} = check, pairs) do
    tenant_id = check.authorization_context.tenant_id

    if FeatureFlags.enabled?(@flag, tenant_id) do
      Task.Supervisor.start_child(Realtime.TaskSupervisor, fn ->
        shadow_start = System.monotonic_time()

        case SqlLogexCache.fetch(db_conn, tenant_id) do
          {:ok, snapshot} ->
            Enum.each(pairs, fn {extension, real} -> compare(check, snapshot, extension, real) end)

          {:error, reason} ->
            Telemetry.execute(check.event ++ [:unavailable], %{count: 1}, %{tenant: tenant_id, reason: inspect(reason)})
        end

        shadow_duration = System.monotonic_time() - shadow_start
        Telemetry.execute(check.event ++ [:timing], %{shadow_duration: shadow_duration}, %{tenant: tenant_id})
      end)
    end

    :ok
  end

  defp compare(%Check{} = check, snapshot, extension, real) do
    tenant_id = check.authorization_context.tenant_id
    metadata = %{tenant: tenant_id, extension: extension}

    try do
      outcome =
        case SqlLogexEnv.build(check.authorization_context, extension) do
          {:ok, env} -> classify(SqlLogex.decide(snapshot, env, check.operation), real)
          {:error, reason} -> {:fallback, reason}
        end

      outcome_metadata = Map.merge(metadata, %{outcome: tag(outcome), real: real, reason: reason(outcome)})
      Telemetry.execute(check.event, %{}, outcome_metadata)

      case outcome do
        {:mismatch, sql_logex, _real} ->
          # topic/role/operation so a mismatch can be checked against the tenant's current policies by
          # hand — a stale cached snapshot (up to the cache TTL old) looks identical to a real bug
          # otherwise. tenant_id rather than project/external_id: those route a log to the tenant's own
          # logs, and this one is ours alone.
          log_warning(
            "SqlLogexShadowMismatch",
            %{
              operation: check.operation,
              extension: extension,
              topic: check.authorization_context.topic,
              role: check.authorization_context.role,
              sql_logex: sql_logex,
              real: real
            },
            tenant_id: tenant_id
          )

        _ ->
          :ok
      end
    rescue
      exception -> Telemetry.execute(check.event ++ [:exception], %{}, Map.merge(metadata, %{reason: exception}))
    end
  end

  defp classify({:fallback, _} = fallback, _real), do: fallback
  defp classify(:allow, true), do: :match
  defp classify(:deny, false), do: :match
  defp classify(decision, nil), do: {:no_real_answer, decision}
  defp classify(decision, real), do: {:mismatch, decision, real}

  defp tag(:match), do: :match
  defp tag({:mismatch, _, _}), do: :mismatch
  defp tag({:fallback, _}), do: :fallback
  defp tag({:no_real_answer, _}), do: :no_real_answer

  defp reason({:fallback, reason}), do: SqlLogex.Reason.category(reason)
  defp reason(_outcome), do: :none

  # Mirrors Realtime.Tenants.Authorization's own update_write_policy/3 mapping, as a getter.
  defp real_read({:ok, %Policies{broadcast: %{read: v}}}, :broadcast), do: v
  defp real_read({:ok, %Policies{presence: %{read: v}}}, :presence), do: v
  defp real_read({:error, :rls_policy_error, error}, _extension), do: policy_error(error)
  defp real_read(_result, _extension), do: nil

  defp real_write({:ok, %Policies{broadcast: %{write: v}}}, :broadcast), do: v
  defp real_write({:ok, %Policies{presence: %{write: v}}}, :presence), do: v
  defp real_write({:ok, %Policies{broadcast: %{persist: v}}}, :persistence), do: v
  defp real_write({:error, :rls_policy_error, error}, _extension), do: policy_error(error)
  defp real_write(_result, _extension), do: nil

  # :rls_policy_error is Authorization's catch-all for any Postgrex.Error. These SQLSTATE classes are
  # the ones evaluating the policies for this input raises:
  #
  #   22  data exception: a sub that isn't a uuid, invalid json
  #   42  syntax error or access rule violation: a revoked EXECUTE
  #   P0  PL/pgSQL error: a RAISE in a function or trigger
  #
  # See https://www.postgresql.org/docs/current/errcodes-appendix.html. Only the code, never the
  # message, which can hold the input.
  @policy_error_classes ["22", "42", "P0"]

  defp policy_error(%Postgrex.Error{postgres: %{pg_code: <<class::binary-size(2), _::binary>> = code}})
       when class in @policy_error_classes,
       do: {:error, code}

  defp policy_error(_error), do: nil
end
