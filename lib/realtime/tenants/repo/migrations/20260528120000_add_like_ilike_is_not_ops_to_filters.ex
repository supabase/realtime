defmodule Realtime.Tenants.Migrations.AddLikeIlikeIsNotOpsToFilters do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("alter type realtime.equality_op add value 'like';")
    execute("alter type realtime.equality_op add value 'ilike';")
    execute("alter type realtime.equality_op add value 'is';")
    execute("alter type realtime.equality_op add value 'not_in';")
    execute("alter type realtime.equality_op add value 'not_like';")
    execute("alter type realtime.equality_op add value 'not_ilike';")
    execute("alter type realtime.equality_op add value 'not_is';")

    execute("
      create or replace function realtime.check_equality_op(
          op realtime.equality_op,
          type_ regtype,
          val_1 text,
          val_2 text
      )
          returns bool
          immutable
          language plpgsql
      as $$
      declare
          op_symbol text;
          res boolean;
      begin
          -- IS / IS NOT require keyword RHS, not a typed literal
          if op = 'is' or op = 'not_is' then
              if val_2 not in ('null', 'true', 'false', 'unknown') then
                  raise exception 'invalid value for is/not_is filter: must be null, true, false, or unknown';
              end if;
              execute format(
                  'select %L::%s %s %s',
                  val_1,
                  type_::text,
                  case when op = 'is' then 'IS' else 'IS NOT' end,
                  upper(val_2)
              ) into res;
              return res;
          end if;

          op_symbol = case
              when op = 'eq'        then '='
              when op = 'neq'       then '!='
              when op = 'lt'        then '<'
              when op = 'lte'       then '<='
              when op = 'gt'        then '>'
              when op = 'gte'       then '>='
              when op = 'in'        then '= any'
              when op = 'not_in'    then '!= all'
              when op = 'like'      then 'LIKE'
              when op = 'ilike'     then 'ILIKE'
              when op = 'not_like'  then 'NOT LIKE'
              when op = 'not_ilike' then 'NOT ILIKE'
              else null
          end;

          if op_symbol is null then
              raise exception 'unsupported equality operator: %', op::text;
          end if;

          execute format(
              'select %L::'|| type_::text || ' ' || op_symbol
              || ' ( %L::'
              || (
                  case
                      when op in ('in', 'not_in') then type_::text || '[]'
                      else type_::text
                  end
              )
              || ')', val_1, val_2) into res;
          return res;
      end;
      $$;
    ")

    execute("
      create or replace function realtime.subscription_check_filters()
          returns trigger
          language plpgsql
      as $$
      declare
          col_names text[] = coalesce(
                  array_agg(c.column_name order by c.ordinal_position),
                  '{}'::text[]
              )
              from
                  information_schema.columns c
              where
                  format('%I.%I', c.table_schema, c.table_name)::regclass = new.entity
                  and pg_catalog.has_column_privilege(
                      (new.claims ->> 'role'),
                      format('%I.%I', c.table_schema, c.table_name)::regclass,
                      c.column_name,
                      'SELECT'
                  );
          filter realtime.user_defined_filter;
          col_type regtype;
          in_val jsonb;
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

              if filter.op in ('in'::realtime.equality_op, 'not_in'::realtime.equality_op) then
                  in_val = realtime.cast(filter.value, (col_type::text || '[]')::regtype);
                  if coalesce(jsonb_array_length(in_val), 0) > 100 then
                      raise exception 'too many values for `in`/`not_in` filter. Maximum 100';
                  end if;
              elsif filter.op in ('is'::realtime.equality_op, 'not_is'::realtime.equality_op) then
                  if filter.value not in ('null', 'true', 'false', 'unknown') then
                      raise exception 'invalid value for is/not_is filter: must be null, true, false, or unknown';
                  end if;
              else
                  perform realtime.cast(filter.value, col_type);
              end if;
          end loop;

          new.filters = coalesce(
              array_agg(f order by f.column_name, f.op, f.value),
              '{}'
          ) from unnest(new.filters) f;

          return new;
      end;
      $$;
    ")
  end
end
