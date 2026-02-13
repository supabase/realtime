defmodule Realtime.Tenants.Migrations.SupportIsNullFilter do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("alter type realtime.equality_op add value 'isnull';")
    execute("alter type realtime.equality_op add value 'notnull';")

    execute("
CREATE OR REPLACE FUNCTION realtime.check_equality_op(op realtime.equality_op, type_ regtype, val_1 text, val_2 text)
 RETURNS boolean
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
      /*
      Casts *val_1* and *val_2* as type *type_* and check the *op* condition for truthiness
      */
      declare
          op_symbol text = (
              case
                  when op = 'eq' then '='
                  when op = 'neq' then '!='
                  when op = 'lt' then '<'
                  when op = 'lte' then '<='
                  when op = 'gt' then '>'
                  when op = 'gte' then '>='
                  when op = 'in' then '= any'
                  when op in ('isnull', 'notnull') then op
                  else 'UNKNOWN OP'
              end
          );
          res boolean;
      begin
          if op in ('isnull', 'notnull') then
              execute format('select %L::'|| type_::text || ' ' || op_symbol, val_1) into res;
          else
              execute format(
                  'select %L::'|| type_::text || ' ' || op_symbol
                  || ' ( %L::'
                  || (
                      case
                          when op = 'in' then type_::text || '[]'
                          else type_::text end
                  )
                  || ')', val_1, val_2) into res;
          end if;
          return res;
      end;
      $function$
    ")
  end
end
