defmodule Realtime.Tenants.Migrations.AuthorizeWritesSkipSelect do
  @moduledoc false

  use Ecto.Migration

  def change do
    # A write-only call no longer runs the SELECT that reads the probes back. With no probes it
    # returned no rows, but Postgres still planned it as the user's role: it checked the SELECT
    # privilege, added the SELECT policies and folded their constants. So a role without SELECT,
    # or a SELECT policy that raises when planned, failed a write that the INSERT policies allow.
    # The transaction path only runs the INSERT, so both paths now answer a write the same way.
    #
    # read_allowed is still assigned on a write-only call: array() over no rows is '{}', which is
    # what Authorization expects back for no read extensions.
    execute(~S"""
    CREATE OR REPLACE FUNCTION realtime.authorize(
      role_name text,
      topic_name text,
      claims text,
      sub text,
      headers text,
      read_extensions text[],
      write_extensions text[],
      OUT read_allowed boolean[],
      OUT write_allowed boolean[])
    LANGUAGE plpgsql
    VOLATILE
    AS $$
    declare
      probe_ids uuid[];
      probe_inserted_at timestamp := now() at time zone 'utc';
      visible_ids uuid[];
      ext text;
      allowed boolean;
    begin
      -- The probe inserts are rolled back, but they still give the transaction an xid, so it ends
      -- in a commit. Nothing durable was written, so skip waiting on the WAL flush and sync standbys.
      -- Set outside the block below, whose rollback would undo it.
      perform set_config('synchronous_commit', 'off', true);

      -- The RAISE at the end of this block rolls back everything in it.
      begin
        probe_ids := array(select gen_random_uuid() from unnest(read_extensions));

        insert into realtime.messages (id, topic, extension, inserted_at, updated_at)
        select p.id, topic_name, p.extension, probe_inserted_at, probe_inserted_at
        from unnest(probe_ids, read_extensions) as p(id, extension);

        perform set_config('role', role_name, true),
                set_config('realtime.topic', topic_name, true),
                set_config('request.jwt.claims', claims, true),
                set_config('request.jwt.claim.sub', sub, true),
                set_config('request.jwt.claim.role', role_name, true),
                set_config('request.headers', headers, true);

        -- One lookup for every probe, by the full primary key. Skipped without probes, so the
        -- SELECT policies are not planned for a write.
        if cardinality(probe_ids) > 0 then
          visible_ids := array(
            select m.id
            from realtime.messages m
            where m.inserted_at = probe_inserted_at
              and m.id = any(probe_ids));
        end if;

        read_allowed := array(
          select p.id = any(visible_ids)
          from unnest(probe_ids) with ordinality as p(id, n)
          order by p.n);

        write_allowed := '{}';

        foreach ext in array write_extensions loop
          begin
            insert into realtime.messages (topic, extension, inserted_at, updated_at)
            values (topic_name, ext, now() at time zone 'utc', now() at time zone 'utc');

            allowed := true;
          exception when insufficient_privilege then
            allowed := false;
          end;

          write_allowed := write_allowed || allowed;
        end loop;

        raise sqlstate 'RTA01';
      exception when sqlstate 'RTA01' then
        null;
      end;
    end;
    $$;
    """)

    execute(
      "ALTER FUNCTION realtime.authorize(text, text, text, text, text, text[], text[]) OWNER TO supabase_realtime_admin"
    )
  end
end
