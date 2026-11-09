# The tests tagged :postgres run SQL against a real Postgres, the oracle of the library. They run
# only when SQL_LOGEX_DATABASE_URL is set. See "Tests against Postgres" in the README.
exclude =
  if SqlLogex.Test.Postgres.url() do
    major = SqlLogex.Test.Postgres.prepare!()
    writing? = System.get_env("SQL_LOGEX_WRITE_FIXTURES") == "1"

    if writing? or File.exists?(SqlLogex.Test.Postgres.fixture_path(major)) do
      []
    else
      IO.puts("No fixture for Postgres #{major}, so the fixtures test is excluded.")
      [:fixtures]
    end
  else
    [:postgres]
  end

ExUnit.start(exclude: exclude)
