import Ecto.Adapters.SQL, only: [query: 3]

[
  "drop publication realtime_test",
  "create publication realtime_test for all tables"
] |> Enum.each(&query(Realtime.Repo, &1, []))
