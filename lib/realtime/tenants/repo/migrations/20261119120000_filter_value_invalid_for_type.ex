defmodule Realtime.Tenants.Migrations.FilterValueInvalidForType do
  @moduledoc false

  use Ecto.Migration

  def change do
    # subscription_check_filters checks a filter value against the column type only when the
    # subscription is created. A later schema change, such as renaming an enum value or changing
    # the column type, can leave the value unreadable as the current type, and check_equality_op
    # raised for every change to the table. That aborted apply_rls and the whole list_changes
    # poll, for every table and subscriber of the tenant. Such a filter now never matches.
    execute("""
    create or replace function realtime.check_equality_op(
        op realtime.equality_op,
        type_ regtype,
        val_1 text,
        val_2 text,
        negate boolean
    )
        returns boolean
        language plpgsql
        stable
    as $$
    declare
        op_symbol text;
        res boolean;
    begin
        -- IS DISTINCT FROM / IS NOT DISTINCT FROM: infix, both sides typed literals
        if op = 'isdistinct' then
            execute format(
                'select %L::%s %s %L::%s',
                val_1,
                type_::text,
                case when negate then 'IS NOT DISTINCT FROM' else 'IS DISTINCT FROM' end,
                val_2,
                type_::text
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
                type_::text,
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
            type_::text,
            op_symbol,
            val_2,
            case when op = 'in' then type_::text || '[]' else type_::text end
        ) into res;

        return case when negate then not res else res end;
    exception
        -- The filter value was valid for the column type when the subscription was created, but
        -- a later schema change can leave it unreadable as the current type, or leave an operator
        -- that no longer applies. Raising here would abort apply_rls for every subscriber of the
        -- tenant, so a filter that can no longer be evaluated does not match.
        when data_exception
            or integrity_constraint_violation
            or datatype_mismatch
            or undefined_function then
            return false;
    end;
    $$;
    """)
  end
end
