defmodule Mix.Tasks.Seed do
  use Mix.Task

  @shortdoc "Seed main database with tenant"
  def run(_) do
    :httpc.request(
      :put,
      {'http://localhost:4000/api/tenants/dev_tenant',
       [
         {'Authorization',
          'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJvbGUiOiJhbm9uIiwiaWF0IjoxNjQ1MTkyODI0LCJleHAiOjE5NjA3Njg4MjR9.M9jrxyvPLkUxWgOYSf5dNdJ8v_eRrq810ShFRT8N-6M'}
       ], 'application/json', '{"tenant": {
                "name": "dev_tenant",
                "extensions": [
                  {
                    "type": "postgres",
                    "settings": {
                        "db_host": "127.0.0.1",
                        "db_name": "postgres",
                        "db_user": "postgres",
                        "db_password": "postgres",
                        "db_port": "5432",
                        "poll_interval_ms": 100,
                        "poll_max_changes": 100,
                        "poll_max_record_bytes": 1048576,
                        "region": "us-east-1"
                    }
                  }
                ],
              "jwt_secret": "d3v_HtNXEpT+zfsyy1LE1WPGmNKLWRfw/rpjnVtCEEM2cSFV2s+kUh5OKX7TPYmG"
              }}'},
      [],
      []
    )
  end
end
