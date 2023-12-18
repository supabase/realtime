defmodule Realtime.Tenants.Migrations.CreateRlsHelperFunctions do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("""
    create or replace function realtime.channel_name() returns text as $$
    select nullif(current_setting('realtime.channel_name', true), '')::text;
    $$ language sql stable;
    """)

    execute("create schema if not exists auth")

    execute("""
    do $func_exists$
    begin if not exists(select * from pg_proc where proname = 'role')
    then
      create or replace function auth.uid() returns uuid as $function_def$
        select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
      $function_def$ language sql stable;
    end if;
    end $func_exists$;
    """)

    execute("""
    do $func_exists$
    begin if not exists(select * from pg_proc where proname = 'role')
    then
      create function auth.role() returns text as $function_def$
        select nullif(current_setting('request.jwt.claim.role', true), '')::text;
      $function_def$ language sql stable;
    end if;
    end $func_exists$;
    """)
  end
end
