create or replace function realtime.authorize (
  role_name        text,
  topic_name       text,
  claims           text,
  sub              text,
  headers          text,
  read_extensions  text[],
  write_extensions text[],
  OUT              read_allowed boolean[],
  OUT              write_allowed boolean[]
)
  returns record
  language plpgsql
  AS $function$
declare
  probe_ids uuid[];
  ext text;
  allowed boolean;
begin
  -- The RAISE at the end of this block rolls back everything in it.
  begin
    probe_ids := array(select gen_random_uuid() from unnest(read_extensions));

    insert into realtime.messages (id, topic, extension, inserted_at, updated_at)
    select p.id, topic_name, p.extension, now() at time zone 'utc', now() at time zone 'utc'
    from unnest(probe_ids, read_extensions) as p(id, extension);

    perform set_config('role', role_name, true),
            set_config('realtime.topic', topic_name, true),
            set_config('request.jwt.claims', claims, true),
            set_config('request.jwt.claim.sub', sub, true),
            set_config('request.jwt.claim.role', role_name, true),
            set_config('request.headers', headers, true);

    read_allowed := array(
      select exists(select 1 from realtime.messages m where m.id = p.id)
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
$function$;

alter function "realtime"."authorize"(text, text, text, text, text, text[], text[]) owner to "supabase_realtime_admin";
