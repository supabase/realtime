defmodule Realtime.Tenants.Authorization do
  @moduledoc """
  Runs validations based on RLS policies to return policies and
  creates a Realtime.Tenants.Policies struct with the accumulated results of the policies
  for a given user and a given channel context

  Each extension will have its own set of ways to check Policies against the Authorization context
  but we will create some setup data to be used by the policies.

  Check more information at Realtime.Tenants.Authorization.Policies
  """
  use Realtime.Logs

  import Ecto.Query

  alias DBConnection.ConnectionError
  alias Realtime.Api.Message
  alias Realtime.Api.Tenant
  alias Realtime.Database
  alias Realtime.FeatureFlags
  alias Realtime.GenCounter
  alias Realtime.GenRpc
  alias Realtime.Tenants.Repo
  alias Realtime.Tenants.Authorization.Policies

  defstruct [:tenant_id, :topic, :headers, :jwt, :claims, :role, :sub]

  @type t :: %__MODULE__{
          :tenant_id => binary | nil,
          :topic => binary | nil,
          :claims => map,
          :headers => list({binary, binary}),
          :role => binary,
          :sub => binary | nil
        }

  @type extension :: :broadcast | :presence | :persistence

  @doc """
  Builds a new authorization struct which will be used to retain the information required to check Policies.

  Requires a map with the following keys:
  * tenant_id: The tenant id
  * topic: The name of the channel being accessed taken from the request
  * headers: Request headers when the connection was made or WS was upgraded
  * claims: JWT claims
  * role: JWT role claim
  * sub: JWT sub claim
  """
  @spec build_authorization_params(map()) :: t()
  def build_authorization_params(map) do
    %__MODULE__{
      tenant_id: Map.get(map, :tenant_id),
      topic: Map.get(map, :topic),
      headers: Map.get(map, :headers),
      claims: Map.get(map, :claims),
      role: Map.get(map, :role),
      sub: Map.get(map, :sub)
    }
  end

  @doc """
  Runs validations based on RLS policies to return policies for read policies

  Automatically uses RPC if the database connection is not in the same node
  """
  @spec get_read_authorizations(Policies.t(), pid(), t(), keyword()) ::
          {:ok, Policies.t()}
          | {:error, :rls_policy_error, Postgrex.Error.t()}
          | {:error, :query_canceled, Postgrex.Error.t()}
          | {:error, :missing_partition}
          | {:error, :increase_connection_pool}
          | {:error, :tenant_database_unavailable}
          | {:error, any()}
  def get_read_authorizations(policies, db_conn, authorization_context, opts \\ [])

  def get_read_authorizations(policies, db_conn, authorization_context, opts) when node() == node(db_conn) do
    rate_counter = rate_counter(authorization_context.tenant_id)

    if rate_counter.limit.triggered == false do
      db_conn
      |> get_read_policies_for_connection(authorization_context, policies, opts)
      |> handle_policies_result(rate_counter)
    else
      {:error, :increase_connection_pool}
    end
  end

  # Remote call
  def get_read_authorizations(policies, db_conn, authorization_context, opts) do
    rate_counter = rate_counter(authorization_context.tenant_id)

    if rate_counter.limit.triggered == false do
      case GenRpc.call(
             node(db_conn),
             __MODULE__,
             :get_read_authorizations,
             [policies, db_conn, authorization_context, opts],
             tenant_id: authorization_context.tenant_id,
             key: authorization_context.tenant_id
           ) do
        {:error, :increase_connection_pool} = error ->
          GenCounter.add(rate_counter.id)
          error

        {:error, :rpc_error, reason} ->
          {:error, reason}

        response ->
          response
      end
    else
      {:error, :increase_connection_pool}
    end
  end

  @doc """
  Runs validations based on RLS policies to return policies for write policies

  Automatically uses RPC if the database connection is not in the same node
  """
  @spec get_write_authorizations(Policies.t(), pid(), t(), extension()) ::
          {:ok, Policies.t()}
          | {:error, :rls_policy_error, Postgrex.Error.t()}
          | {:error, :query_canceled, Postgrex.Error.t()}
          | {:error, :missing_partition}
          | {:error, :increase_connection_pool}
          | {:error, :tenant_database_unavailable}
          | {:error, any()}
  def get_write_authorizations(policies, db_conn, authorization_context, extension)
      when extension in [:broadcast, :presence, :persistence] and node() == node(db_conn) do
    rate_counter = rate_counter(authorization_context.tenant_id)

    if rate_counter.limit.triggered == false do
      db_conn
      |> get_write_policies_for_connection(authorization_context, policies, extension)
      |> handle_policies_result(rate_counter)
    else
      {:error, :increase_connection_pool}
    end
  end

  # Remote call
  def get_write_authorizations(policies, db_conn, authorization_context, extension)
      when extension in [:broadcast, :presence, :persistence] do
    rate_counter = rate_counter(authorization_context.tenant_id)

    if rate_counter.limit.triggered == false do
      case GenRpc.call(
             node(db_conn),
             __MODULE__,
             :get_write_authorizations,
             [policies, db_conn, authorization_context, extension],
             tenant_id: authorization_context.tenant_id,
             key: authorization_context.tenant_id
           ) do
        {:error, :increase_connection_pool} = error ->
          GenCounter.add(rate_counter.id)
          error

        {:error, :rpc_error, reason} ->
          {:error, reason}

        response ->
          response
      end
    else
      {:error, :increase_connection_pool}
    end
  end

  def get_write_authorizations(db_conn, authorization_context, extension),
    do: get_write_authorizations(%Policies{}, db_conn, authorization_context, extension)

  defp handle_policies_result(result, rate_counter) do
    case result do
      {:ok, %Policies{} = policies} ->
        {:ok, policies}

      {:ok, {:error, %Postgrex.Error{} = error}} ->
        {:error, :rls_policy_error, error}

      {:error, %Postgrex.Error{postgres: %{code: :invalid_parameter_value}} = error} ->
        {:error, :rls_policy_error, error}

      {:error, %Postgrex.Error{postgres: %{code: :query_canceled}} = error} ->
        {:error, :query_canceled, error}

      {:error, %Postgrex.Error{postgres: %{code: :check_violation, table: "messages"}}} ->
        {:error, :missing_partition}

      {:error, %Postgrex.Error{} = error} ->
        {:error, :rls_policy_error, error}

      {:error, %ConnectionError{reason: :queue_timeout}} ->
        GenCounter.add(rate_counter.id)
        {:error, :increase_connection_pool}

      {:error, {:exit, _}} ->
        GenCounter.add(rate_counter.id)
        {:error, :increase_connection_pool}

      {:error, %ConnectionError{}} ->
        {:error, :tenant_database_unavailable}

      {:error, error} ->
        {:error, error}
    end
  end

  @all_extensions [:broadcast, :presence]

  defp get_read_policies_for_connection(conn, authorization_context, policies, caller_opts) do
    extensions = extensions_to_check(caller_opts)

    check_with_fallback(
      authorization_context,
      fn -> read_policies_with_function(conn, authorization_context, policies, extensions) end,
      fn -> read_policies_with_transaction(conn, authorization_context, policies, extensions) end
    )
  end

  defp get_write_policies_for_connection(conn, authorization_context, policies, extension) do
    check_with_fallback(
      authorization_context,
      fn -> write_policies_with_function(conn, authorization_context, policies, extension) end,
      fn -> write_policies_with_transaction(conn, authorization_context, policies, extension) end
    )
  end

  defp extensions_to_check(opts) do
    if Keyword.get(opts, :presence_enabled?, true),
      do: @all_extensions,
      else: [:broadcast]
  end

  # With the flag on, policies are checked by realtime.authorize in a single round trip. If calling
  # the function itself fails, such as it not existing yet on a database still being migrated, the
  # check is redone in a transaction. Any other error is returned as is.
  defp check_with_fallback(authorization_context, function_check, transaction_check) do
    %__MODULE__{tenant_id: tenant_id} = authorization_context

    if FeatureFlags.enabled?("use_authorize_function", tenant_id) do
      case function_check.() do
        {:error, reason} = error ->
          if fallback?(reason) do
            log_warning("AuthorizeFunctionFallback", reason, project: tenant_id, external_id: tenant_id)
            transaction_check.()
          else
            error
          end

        result ->
          result
      end
    else
      transaction_check.()
    end
  end

  # Only failures of the function itself fall back
  defp fallback?(%Postgrex.Error{postgres: %{code: :undefined_function, message: "function realtime.authorize(" <> _}}),
    do: true

  defp fallback?({:unexpected_result, _}), do: true
  defp fallback?(_), do: false

  @authorize_query "SELECT read_allowed, write_allowed FROM realtime.authorize($1, $2, $3, $4, $5, $6, $7)"

  defp read_policies_with_function(conn, authorization_context, policies, extensions) do
    telemetry = [:realtime, :tenants, :read_authorization_check]

    # Extensions that are not checked are left unevaluated (nil) so callers can tell "denied"
    # (false) apart from "not checked yet" (nil).
    case authorize(conn, authorization_context, extensions, [], telemetry) do
      {:ok, {read_allowed, []}} when length(read_allowed) == length(extensions) ->
        {:ok,
         extensions
         |> Enum.zip(read_allowed)
         |> Enum.reduce(policies, fn {extension, allowed}, acc ->
           Policies.update_policies(acc, extension, :read, allowed)
         end)}

      {:ok, unexpected} ->
        {:error, {:unexpected_result, unexpected}}

      error ->
        error
    end
  end

  defp write_policies_with_function(conn, authorization_context, policies, extension) do
    telemetry = [:realtime, :tenants, :write_authorization_check]

    case authorize(conn, authorization_context, [], [extension], telemetry) do
      {:ok, {[], [allowed]}} -> {:ok, update_write_policy(policies, extension, allowed)}
      {:ok, unexpected} -> {:error, {:unexpected_result, unexpected}}
      error -> error
    end
  end

  defp authorize(conn, authorization_context, read_extensions, write_extensions, telemetry) do
    %__MODULE__{
      tenant_id: tenant_id,
      topic: topic,
      headers: headers,
      claims: claims,
      role: role,
      sub: sub
    } = authorization_context

    params = [
      role,
      topic,
      Jason.encode!(claims),
      sub,
      headers |> Map.new() |> Jason.encode!(),
      Enum.map(read_extensions, &Atom.to_string/1),
      Enum.map(write_extensions, &Atom.to_string/1)
    ]

    opts = [telemetry: telemetry, tenant_id: tenant_id, cache_statement: "realtime_authorize"]
    metadata = [project: tenant_id, external_id: tenant_id, tenant_id: tenant_id]

    case Database.query(conn, @authorize_query, params, opts, metadata) do
      {:ok, %Postgrex.Result{rows: [[read_allowed, write_allowed]]}} -> {:ok, {read_allowed, write_allowed}}
      {:ok, result} -> {:error, {:unexpected_result, result}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Sets the current connection configuration with the following config values:
  * role: The role of the user
  * realtime.topic: The name of the channel being accessed
  * request.jwt.claim.role: The role of the user
  * request.jwt.claim.sub: The sub claim of the JWT token
  * request.jwt.claims: The claims of the JWT token
  * request.headers: The headers of the request
  """
  @spec set_conn_config(DBConnection.t(), t()) :: Postgrex.Result.t()
  def set_conn_config(conn, authorization_context) do
    %__MODULE__{
      topic: topic,
      headers: headers,
      claims: claims,
      role: role,
      sub: sub
    } = authorization_context

    claims = Jason.encode!(claims)
    headers = headers |> Map.new() |> Jason.encode!()

    Postgrex.query!(
      conn,
      """
      SELECT
        set_config('role', $1, true),
        set_config('realtime.topic', $2, true),
        set_config('request.jwt.claims', $3, true),
        set_config('request.jwt.claim.sub', $4, true),
        set_config('request.jwt.claim.role', $5, true),
        set_config('request.headers', $6, true)
      """,
      [role, topic, claims, sub, role, headers]
    )
  end

  defp read_policies_with_transaction(conn, authorization_context, policies, extensions) do
    tenant_id = authorization_context.tenant_id
    opts = [telemetry: [:realtime, :tenants, :read_authorization_check], tenant_id: tenant_id]
    metadata = [project: tenant_id, external_id: tenant_id, tenant_id: tenant_id]

    Database.transaction(
      conn,
      fn transaction_conn ->
        # Generate the probe ids client-side so we can skip RETURNING on the insert and build the
        # extension -> id map deterministically (multi-row RETURNING order is not guaranteed).
        messages_by_extension = Map.new(extensions, &{&1, Ecto.UUID.generate()})

        changesets =
          Enum.map(messages_by_extension, fn {ext, id} ->
            # The raw insert sends params straight to Postgrex (no Ecto casting), so the uuid column
            # needs the 16-byte binary form. The map keeps the string form for the Ecto SELECT below.
            {:ok, dumped_id} = Ecto.UUID.dump(id)

            %Message{}
            |> Message.changeset(%{topic: authorization_context.topic, extension: ext})
            |> Ecto.Changeset.put_change(:id, dumped_id)
          end)

        with {:ok, _} <- Repo.insert_all_entries(transaction_conn, changesets, Message, returning: false),
             _ = set_conn_config(transaction_conn, authorization_context),
             {:ok, policies} <-
               check_read_policies(transaction_conn, messages_by_extension, policies) do
          Postgrex.query!(transaction_conn, "ROLLBACK AND CHAIN", [])
          policies
        else
          {:error, reason} -> DBConnection.rollback(transaction_conn, reason)
        end
      end,
      opts,
      metadata
    )
  end

  defp write_policies_with_transaction(conn, authorization_context, policies, extension) do
    tenant_id = authorization_context.tenant_id
    opts = [telemetry: [:realtime, :tenants, :write_authorization_check], tenant_id: tenant_id]
    metadata = [project: tenant_id, external_id: tenant_id]

    Database.transaction(
      conn,
      fn transaction_conn ->
        set_conn_config(transaction_conn, authorization_context)

        with {:ok, policies} <- check_write_policy(transaction_conn, authorization_context, extension, policies) do
          Postgrex.query!(transaction_conn, "ROLLBACK AND CHAIN", [])
          policies
        else
          {:error, reason} -> DBConnection.rollback(transaction_conn, reason)
        end
      end,
      opts,
      metadata
    )
  end

  defp check_read_policies(conn, messages_by_extension, policies) do
    ids = Map.values(messages_by_extension)

    query = from(m in Message, where: m.id in ^ids, select: m.id)

    with {:ok, res} <- Repo.all(conn, query, Message) do
      returned_ids = MapSet.new(res, & &1.id)

      # Only the requested extensions were inserted, so we only set read for those. Extensions that
      # were not checked are left unevaluated (nil) so callers can tell "denied" (false) apart from
      # "not checked yet" (nil).
      {:ok,
       Enum.reduce(messages_by_extension, policies, fn {extension, id}, acc ->
         Policies.update_policies(acc, extension, :read, MapSet.member?(returned_ids, id))
       end)}
    end
  end

  defp check_write_policy(conn, authorization_context, extension, policies) do
    changeset = Message.changeset(%Message{}, %{topic: authorization_context.topic, extension: extension})

    case Repo.insert(conn, changeset, Message, mode: :savepoint, returning: false) do
      {:ok, _} ->
        {:ok, update_write_policy(policies, extension, true)}

      {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} ->
        {:ok, update_write_policy(policies, extension, false)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_write_policy(policies, :persistence, value),
    do: Policies.update_policies(policies, :broadcast, :persist, value)

  defp update_write_policy(policies, extension, value),
    do: Policies.update_policies(policies, extension, :write, value)

  defp rate_counter(tenant_id) do
    %Tenant{} = tenant = Realtime.Tenants.Cache.get_tenant_by_external_id(tenant_id)
    rate_counter = Realtime.Tenants.authorization_errors_per_second_rate(tenant)
    {:ok, rate_counter} = Realtime.RateCounter.get(rate_counter)
    rate_counter
  end
end
