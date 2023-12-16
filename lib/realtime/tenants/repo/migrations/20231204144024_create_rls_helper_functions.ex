defmodule Realtime.Tenants.Migrations.CreateRlsHelperFunctions do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("""
    create or replace function realtime.channel_name() returns text as $$
    select nullif(current_setting('realtime.channel_name', true), '')::text;
    $$ language sql stable;
    """)

    execute("""
    create or replace function auth.role() returns text as $$
        select nullif(current_setting('request.jwt.claim.role', true), '')::text;
      $$ language sql stable;
    """)

    execute("""
    create or replace function auth.role() returns text as $$
         select nullif(current_setting('request.jwt.claim.role', true), '')::text;
       $$ language sql stable;
    """)
  end
end
