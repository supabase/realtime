defmodule Realtime.Tenants.Migrations.KeepCharAndBitLengthInCasts do
  @moduledoc false

  use Ecto.Migration

  def change do
    # `realtime.cast` and `realtime.check_equality_op` cast a WAL value with `type_::text`. A regtype
    # carries no type modifier, and its text form for `character` and `bit` is the bare SQL type
    # name, which SQL defines as `character(1)` and `bit(1)`. An explicit cast to either silently
    # truncates, so a `char(21)` primary key became one character: the RLS visibility check then
    # looked up a key that does not exist and dropped every INSERT and UPDATE, DELETE sent a
    # one-character `old_record`, and filters compared truncated values.
    #
    # `format_type(type_, -1)` names those types `bpchar` and `"bit"`, which take no implicit
    # length. For every other type it returns the same text as `type_::text`.
    execute(~S"""
    create or replace function realtime.cast(val text, type_ regtype)
      returns jsonb
      immutable
      language plpgsql
    as $$
    declare
      res jsonb;
    begin
      if type_::text = 'bytea' then
        return to_jsonb(val);
      end if;
      execute format('select to_jsonb(%L::'|| pg_catalog.format_type(type_, -1) || ')', val) into res;
      return res;
    end
    $$;
    """)

    execute(~S"""
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
    /*
    Casts *val_1* and *val_2* as type *type_* and check the *op* condition for truthiness
    */
    declare
        type_name text = pg_catalog.format_type(type_, -1);
        op_symbol text = (
            case
                when op = 'eq' then '='
                when op = 'neq' then '!='
                when op = 'lt' then '<'
                when op = 'lte' then '<='
                when op = 'gt' then '>'
                when op = 'gte' then '>='
                when op = 'in' then '= any'
                else 'UNKNOWN OP'
            end
        );
        res boolean;
    begin
        execute format(
            'select %L::'|| type_name || ' ' || op_symbol
            || ' ( %L::'
            || (
                case
                    when op = 'in' then type_name || '[]'
                    else type_name end
            )
            || ')', val_1, val_2) into res;
        return res;
    end;
    $$;
    """)

    execute(~S"""
    create or replace function realtime.check_equality_op(
        op realtime.equality_op,
        type_ regtype,
        val_1 text,
        val_2 text,
        negate boolean
    )
        returns bool
        stable  -- uses EXECUTE, so cannot be immutable
        language plpgsql
    as $$
    declare
        type_name text = pg_catalog.format_type(type_, -1);
        op_symbol text;
        res boolean;
    begin
        -- IS DISTINCT FROM / IS NOT DISTINCT FROM: infix, both sides typed literals
        if op = 'isdistinct' then
            execute format(
                'select %L::%s %s %L::%s',
                val_1,
                type_name,
                case when negate then 'IS NOT DISTINCT FROM' else 'IS DISTINCT FROM' end,
                val_2,
                type_name
            ) into res;
            return res;
        end if;

        -- IS requires a keyword RHS (NULL, TRUE, FALSE, UNKNOWN), not a typed literal
        if op = 'is' then
            if val_2 not in ('null', 'true', 'false', 'unknown') then
                raise exception 'invalid value for is filter: must be null, true, false, or unknown';
            end if;
            execute format(
                'select %L::%s %s %s',
                val_1,
                type_name,
                case when negate then 'IS NOT' else 'IS' end,
                upper(val_2)
            ) into res;
            return res;
        end if;

        op_symbol = case
            when op = 'eq'    then '='
            when op = 'neq'   then '!='
            when op = 'lt'    then '<'
            when op = 'lte'   then '<='
            when op = 'gt'    then '>'
            when op = 'gte'   then '>='
            when op = 'in'    then '= any'
            when op = 'like'   then 'LIKE'
            when op = 'ilike'  then 'ILIKE'
            when op = 'match'  then '~'
            when op = 'imatch' then '~*'
            else null
        end;

        if op_symbol is null then
            raise exception 'unsupported equality operator: %', op::text;
        end if;

        execute format(
            'select %L::%s %s (%L::%s)',
            val_1,
            type_name,
            op_symbol,
            val_2,
            case when op = 'in' then type_name || '[]' else type_name end
        ) into res;

        return case when negate then not res else res end;
    end;
    $$;
    """)
  end
end
