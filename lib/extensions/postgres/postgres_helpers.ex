defmodule Extensions.Postgres.Helpers do
  def filter_postgres_settings(extensions) do
    [postgres] =
      Enum.filter(extensions, fn e ->
        if e.type == "postgres_cdc_rls" do
          true
        else
          false
        end
      end)

    postgres.settings
  end
end
