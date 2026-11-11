defmodule PolicyEval.Differential do
  @moduledoc """
  Compares the answers of the library with the answers of Postgres, in tests. Postgres is the
  oracle: its answer is the correct answer.

  A caller that uses `PolicyEval.decide/3` in place of the database can run its own policies through
  both. Then it knows that, for those policies and inputs, the library gives the answer of
  Postgres or falls back.

  Each comparison ends in one class:

    * `:match` - the same value
    * `:fallback` - the library fell back. The caller then asks the database, so this is safe.
      `report/2` counts the fallbacks
    * `:mismatch` - a different value, or a value where Postgres raised an error
    * `:crash` - the library raised an exception

  A mismatch and a crash are failures. `verify!/1` raises for them, which fails an ExUnit test.

  This module does not connect to a database. The caller asks Postgres, and gives the answers to
  `compare/3`.

  ## Example

  The policy and the profile are the ones of "How it works" in the README. The test creates the
  policies in a transaction that rolls back, reads the snapshot input, and asks Postgres in the
  same transaction:

      env = PolicyEval.Env.new(%{"role" => "member", "app.team" => "red"}, %{"team" => {:text, "blue"}})

      {input, postgres} =
        MyApp.Policies.rolled_back(conn, fn conn ->
          Postgrex.query!(conn, ~s(CREATE POLICY "own team" ON app.docs FOR SELECT TO member USING (team = app.team())), [])
          {MyApp.Policies.snapshot_input(conn), MyApp.Policies.ask_postgres(conn, env, :read)}
        end)

      library = PolicyEval.Differential.decide(PolicyEval.Snapshot.new(input, MyApp.Policies.profile()), env, :read)

      [PolicyEval.Differential.compare(postgres, library, name: "a member reads a row of another team")]
      |> PolicyEval.Differential.verify!()

  `ask_postgres` asks the way the application asks in production. For a read, it can insert a row
  as the table owner, set the role and the settings of the env with `set_config`, and select the
  row back. It returns `{:ok, value}`, or `{:error, sqlstate, code, message}` when Postgres raises.
  With Postgrex, these are the fields `pg_code`, `code` and `message` of `Postgrex.Error.postgres`.
  """

  alias PolicyEval.Env
  alias PolicyEval.Snapshot

  @typedoc "The answer of Postgres: a value, or the error that it raised."
  @type postgres_answer ::
          {:ok, term()} | {:error, sqlstate :: String.t(), code :: atom(), message :: String.t()}

  @typedoc "The answer of the library: a value, a fallback with its reason, or an exception."
  @type library_answer :: {:value, term()} | {:unsupported, term()} | {:crash, term()}

  @type class :: :match | :fallback | :mismatch | :crash

  @typedoc """
  The result of one comparison.

  `sub` gives more detail about the class:

    * for a mismatch, `:postgres_value` or `:postgres_error`: what Postgres did
    * for a fallback, `:postgres_value` (Postgres returned a value), `:postgres_error_predicted`
      (Postgres raised the error that the reason of the fallback names),
      `:postgres_error_other_sqlstate` (Postgres raised another error), or `:postgres_error`
      (Postgres raised, and the reason names no error)

  The caller can put anything in `meta`.
  """
  @type result :: %{
          name: String.t() | nil,
          group: term(),
          class: class(),
          sub: atom() | nil,
          postgres: postgres_answer(),
          library: library_answer(),
          detail: String.t(),
          meta: map()
        }

  @classes [:match, :fallback, :mismatch, :crash]

  defmodule VerificationError do
    @moduledoc "Raised by `PolicyEval.Differential.verify!/1`. `failures` holds the results that fail."
    defexception [:message, failures: []]
  end

  @doc """
  The answer of `PolicyEval.decide/3`: `{:value, true}` for `:allow`, `{:value, false}` for `:deny`,
  `{:unsupported, reason}` for a fallback, and `{:crash, reason}` for an exception.
  """
  @spec decide(Snapshot.t(), Env.t(), :read | :write) :: library_answer()
  def decide(snapshot, env, operation) do
    case PolicyEval.decide(snapshot, env, operation) do
      decision when decision in [:allow, :deny] -> {:value, decision == :allow}
      {:fallback, {:exception, _module} = reason} -> {:crash, reason}
      {:fallback, reason} -> {:unsupported, reason}
    end
  rescue
    exception -> {:crash, Exception.format(:error, exception, __STACKTRACE__)}
  end

  @doc """
  Compares an answer of Postgres with an answer of the library. `fields` sets the other fields of
  the result, for example `:name`, `:group`, `:detail` and `:meta`.
  """
  @spec compare(postgres_answer(), library_answer(), keyword()) :: result()
  def compare(postgres, library, fields \\ []) do
    {class, sub} = classify(postgres, library)

    %{name: nil, group: nil, detail: "", meta: %{}}
    |> Map.merge(Map.new(fields))
    |> Map.merge(%{class: class, sub: sub, postgres: postgres, library: library})
  end

  @doc """
  Returns `:ok` if no result fails. Otherwise it raises `PolicyEval.Differential.VerificationError`,
  with each failure in the message. A mismatch and a crash fail.
  """
  @spec verify!([result()]) :: :ok
  def verify!(results) do
    case Enum.filter(results, &(&1.class in [:mismatch, :crash])) do
      [] ->
        :ok

      failures ->
        by_class = failures |> Enum.frequencies_by(& &1.class) |> Enum.map_join(", ", fn {c, n} -> "#{n} #{c}" end)

        message = """
        #{length(failures)} of #{length(results)} comparisons fail (#{by_class}).

        #{Enum.map_join(failures, "\n", &format_result/1)}\
        """

        raise VerificationError, message: message, failures: failures
    end
  end

  @doc """
  A report of `results` under `title`: the number of results in each class, the classes by group,
  and the 25 most frequent reasons of the fallbacks.
  """
  @spec report([result()], String.t()) :: String.t()
  def report(results, title) do
    counts = Enum.frequencies_by(results, & &1.class)
    count = fn class -> Map.get(counts, class, 0) end

    matches = Enum.filter(results, &(&1.class == :match))
    fallbacks = Enum.filter(results, &(&1.class == :fallback))
    values = Enum.frequencies(for %{postgres: {:ok, value}} <- matches, do: value)
    subs = Enum.frequencies_by(fallbacks, & &1.sub)
    raised = length(fallbacks) - Map.get(subs, :postgres_value, 0)

    group_lines =
      results
      |> Enum.group_by(& &1.group)
      |> Enum.sort()
      |> Enum.map(fn {group, in_group} ->
        frequencies = Enum.frequencies_by(in_group, & &1.class)
        classes = for class <- @classes, frequencies[class], do: "#{class} #{frequencies[class]}"
        "    #{group}: #{length(in_group)} (#{Enum.join(classes, ", ")})"
      end)

    reason_lines =
      fallbacks
      |> Enum.frequencies_by(&reason_key(&1.library))
      |> Enum.sort_by(fn {key, n} -> {-n, key} end)
      |> Enum.take(25)
      |> Enum.map(fn {key, n} -> "    #{String.pad_leading(Integer.to_string(n), 5)}  #{key}" end)

    """
    #{title}: #{length(results)} cases
      match     #{count.(:match)}   (Postgres returned true #{values[true] || 0}, false #{values[false] || 0}, NULL #{values[nil] || 0})
      fallback  #{count.(:fallback)}   (Postgres returned a value: #{subs[:postgres_value] || 0}; Postgres raised: #{raised}, of which the library predicted #{subs[:postgres_error_predicted] || 0}, did not predict #{subs[:postgres_error] || 0}, predicted another error #{subs[:postgres_error_other_sqlstate] || 0})
      mismatch  #{count.(:mismatch)}
      crash     #{count.(:crash)}
      groups:
    #{Enum.join(group_lines, "\n")}
      fallback reasons:
    #{Enum.join(reason_lines, "\n")}
    """
  end

  # A result, as the failure message of verify!/1 prints it
  defp format_result(result) do
    """
    #{if result.group, do: "[#{result.group}] "}#{result.name}
      #{result.class}#{if result.sub, do: " (#{result.sub})"}
      postgres: #{format_postgres(result.postgres)}
      library:  #{format_library(result.library)}
    #{result.detail}\
    """
  end

  defp format_postgres({:ok, value}), do: "returned #{inspect(value)}"
  defp format_postgres({:error, sqlstate, code, message}), do: "raised #{sqlstate} #{code}: #{message}"

  defp format_library({:value, value}), do: inspect(value)
  defp format_library({:unsupported, reason}), do: "unsupported #{inspect(reason, limit: 12, printable_limit: 200)}"
  defp format_library({:crash, reason}), do: "crashed #{inspect(reason, limit: 12, printable_limit: 400)}"

  # Postgres raised, and the library fell back: because it saw the error coming, because it saw
  # another error coming, or for another reason. None of these fails
  defp classify(_postgres, {:crash, _reason}), do: {:crash, nil}
  defp classify({:ok, value}, {:value, value}), do: {:match, nil}
  defp classify({:ok, _value}, {:value, _other}), do: {:mismatch, :postgres_value}
  defp classify({:ok, _value}, {:unsupported, _reason}), do: {:fallback, :postgres_value}
  defp classify({:error, _sqlstate, _code, _message}, {:value, _value}), do: {:mismatch, :postgres_error}

  defp classify({:error, _sqlstate, code, _message}, {:unsupported, reason}) do
    case raises_code(reason) do
      nil -> {:fallback, :postgres_error}
      ^code -> {:fallback, :postgres_error_predicted}
      _other -> {:fallback, :postgres_error_other_sqlstate}
    end
  end

  # The error that a reason names, as in {:raises, :invalid_text_representation, detail}
  defp raises_code({:raises, code, _detail}), do: code
  defp raises_code(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.find_value(&raises_code/1)
  defp raises_code(list) when is_list(list), do: Enum.find_value(list, &raises_code/1)
  defp raises_code(_other), do: nil

  defp reason_key({:unsupported, reason}), do: reason_key(reason)
  defp reason_key({:raises, code, _detail}), do: "raises #{code}"
  defp reason_key(reason), do: inspect(reason, limit: 6, printable_limit: 60)
end
