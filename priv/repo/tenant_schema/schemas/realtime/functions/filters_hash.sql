create or replace function realtime.filters_hash (
  filters realtime.user_defined_filter[]
)
  returns bytea
  language sql
  immutable
  parallel safe
  strict
  AS $function$
      select pg_catalog.sha256(pg_catalog.convert_to(filters::text, 'UTF8'))
    $function$;

alter function "realtime"."filters_hash"(realtime.user_defined_filter[]) owner to "supabase_realtime_admin";

grant execute on function "realtime"."filters_hash"(realtime.user_defined_filter[]) to "anon", "authenticated", "service_role";
