create or replace function realtime.is_visible_through_filters (
  columns realtime.wal_column[],
  filters realtime.user_defined_filter[]
)
  returns boolean
  language sql
  stable
  AS $function$
    select
        filters is null
        or array_length(filters, 1) is null
        or coalesce(
            count(col.name) = count(1)
            and sum(
                realtime.check_equality_op(
                    op:=f.op,
                    type_:=case
                        when position('->>' in f.column_name) > 0 then 'text'::regtype
                        else coalesce(col.type_oid::regtype, col.type_name::regtype)
                    end,
                    val_1:=case
                        when position('->>' in f.column_name) > 0 then col.value ->> btrim(split_part(f.column_name, '->>', 2), ' "')
                        else col.value #>> '{}'
                    end,
                    val_2:=f.value,
                    negate:=coalesce(f.negate, false)
                )::int
            ) filter (where col.name is not null) = count(col.name),
            false
        )
    from
        unnest(filters) f
        left join unnest(columns) col
            on split_part(f.column_name, '->>', 1) = col.name
           and (
             position('->>' in f.column_name) = 0
             or coalesce(col.type_oid::regtype, col.type_name::regtype) = 'jsonb'::regtype
           );
$function$;

alter function "realtime"."is_visible_through_filters"(realtime.wal_column[], realtime.user_defined_filter[]) owner to "supabase_realtime_admin";

grant execute on function "realtime"."is_visible_through_filters"(realtime.wal_column[], realtime.user_defined_filter[]) to "anon", "authenticated", "service_role";
