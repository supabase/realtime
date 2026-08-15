create or replace function realtime.subscription_check_filters()
  returns trigger
  language plpgsql
  AS $function$
declare
    col_names text[] = coalesce(
            array_agg(a.attname order by a.attnum),
            '{}'::text[]
        )
        from
            pg_catalog.pg_attribute a
        where
            a.attrelid = new.entity
            and a.attnum > 0
            and not a.attisdropped
            and pg_catalog.has_column_privilege(
                (new.claims ->> 'role'),
                a.attrelid,
                a.attnum,
                'SELECT'
            );
    filter realtime.user_defined_filter;
    col_type regtype;
    in_val jsonb;
    selected_col text;
begin
    for filter in select * from unnest(new.filters) loop
        if not filter.column_name = any(col_names) then
            raise exception 'invalid column for filter %', filter.column_name;
        end if;

        col_type = (
            select atttypid::regtype
            from pg_catalog.pg_attribute
            where attrelid = new.entity
                  and attname = filter.column_name
        );
        if col_type is null then
            raise exception 'failed to lookup type for column %', filter.column_name;
        end if;

        if filter.op = 'in'::realtime.equality_op then
            in_val = realtime.cast(filter.value, (col_type::text || '[]')::regtype);
            if coalesce(jsonb_array_length(in_val), 0) > 100 then
                raise exception 'too many values for `in` filter. Maximum 100';
            end if;
        elsif filter.op = 'is'::realtime.equality_op then
            -- `is` requires a keyword RHS rather than a typed literal
            if filter.value not in ('null', 'true', 'false', 'unknown') then
                raise exception 'invalid value for is filter: must be null, true, false, or unknown';
            end if;
            -- IS NULL works for any type, but IS TRUE/FALSE/UNKNOWN require a boolean
            -- operand. Reject the non-null keywords on non-boolean columns here so they
            -- don't abort apply_rls at WAL time.
            if filter.value <> 'null' and col_type <> 'boolean'::regtype then
                raise exception 'is % filter requires a boolean column, got %', filter.value, col_type::text;
            end if;
        else
            if filter.op in ('match'::realtime.equality_op, 'imatch'::realtime.equality_op) then
                -- validate the regex eagerly so a bad pattern gets its own error rather than
                -- surfacing as an unsupported operator below
                begin
                    perform '' ~ filter.value;
                exception when others then
                    raise exception 'invalid regular expression for % filter: %', filter.op::text, sqlerrm;
                end;
            elsif filter.op not in ('like'::realtime.equality_op, 'ilike'::realtime.equality_op) then
                -- eq/neq/lt/lte/gt/gte/isdistinct: value must be coercable to the type
                perform realtime.cast(filter.value, col_type);
            end if;

            -- The operator also has to be applicable to the column type. pg_operator answers
            -- that wrongly in both directions - varchar carries no ~~ of its own but resolves
            -- one through text, bytea carries ~~ but no ~~* - so evaluate the operator instead
            -- of looking it up. This is the exact call apply_rls makes, which is what keeps
            -- the two from disagreeing; anything that raises here would otherwise raise at WAL
            -- time, where it aborts the batch for every subscription on the tenant.
            begin
                perform realtime.check_equality_op(filter.op, col_type, filter.value, filter.value, filter.negate);
            exception when others then
                raise exception 'operator % is not supported on column % of type %: %',
                    filter.op::text, filter.column_name, col_type::text, sqlerrm;
            end;
        end if;
    end loop;

    if new.selected_columns is not null then
        for selected_col in select * from unnest(new.selected_columns) loop
            if not selected_col = any(col_names) then
                raise exception 'invalid column for select %', selected_col;
            end if;
        end loop;
    end if;

    -- Apply consistent order to filters so the unique constraint can't be tricked by a
    -- different filter order. negate is part of the sort key.
    new.filters = coalesce(
        array_agg(f order by f.column_name, f.op, f.value, f.negate),
        '{}'
    ) from unnest(new.filters) f;

    new.selected_columns = (
        select array_agg(c order by c)
        from unnest(new.selected_columns) c
    );

    return new;
end;
$function$;

alter function "realtime"."subscription_check_filters"() owner to "supabase_realtime_admin";

grant execute on function "realtime"."subscription_check_filters"() to "anon", "authenticated", "service_role";
