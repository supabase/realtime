# CREDITS
# This file draws heavily from https://github.com/cainophile/pgoutput_decoder
# License: https://github.com/cainophile/pgoutput_decoder/blob/master/LICENSE

# Lifted from epgsql (src/epgsql_binary.erl), this module licensed under
# 3-clause BSD found here: https://raw.githubusercontent.com/epgsql/epgsql/devel/LICENSE

# https://github.com/brianc/node-pg-types/blob/master/lib/builtins.js
# MIT License (MIT)

#  * Following query was used to generate this file:
#  SELECT json_object_agg(UPPER(PT.typname), PT.oid::int4 ORDER BY pt.oid)
#  FROM pg_type PT
#  WHERE typnamespace = (SELECT pgn.oid FROM pg_namespace pgn WHERE nspname = 'pg_catalog') -- Take only builting Postgres types with stable OID (extension types are not guaranted to be stable)
#  AND typtype = 'b' -- Only basic types
#  AND typelem = 0 -- Ignore aliases
#  AND typisdefined -- Ignore undefined types



defmodule Realtime.OidDatabase do
  require Logger

  oid_db = [
    {:bool, 16, 1000},
    {:bpchar, 1042, 1014},
    {:bytea, 17, 1001},
    {:char, 18, 1002},
    {:cidr, 650, 651},
    {:date, 1082, 1182},
    {:daterange, 3912, 3913},
    {:float4, 700, 1021},
    {:float8, 701, 1022},
    {:geometry, 17063, 17071},
    {:hstore, 16935, 16940},
    {:inet, 869, 1041},
    {:int2, 21, 1005},
    {:int4, 23, 1007},
    {:int4range, 3904, 3905},
    {:int8, 20, 1016},
    {:int8range, 3926, 3927},
    {:interval, 1186, 1187},
    {:json, 114, 199},
    {:jsonb, 3802, 3807},
    {:macaddr, 829, 1040},
    {:macaddr8, 774, 775},
    {:point, 600, 1017},
    {:text, 25, 1009},
    {:time, 1083, 1183},
    {:timestamp, 1114, 1115},
    {:timestamptz, 1184, 1185},
    {:timetz, 1266, 1270},
    {:tsrange, 3908, 3909},
    {:tstzrange, 3910, 3911},
    {:uuid, 2950, 2951},
    {:varchar, 1043, 1015},
    {:numeric, 1700, 1700}
  ]

  # TODO: Handle array oid type lookup
  for {type_name, type_id, _array_oid} <- oid_db do
    
    # Logger.debug("OID: " <> unquote(type_name))
    # Logger.debug("OID pt.2: " <> unquote(type_id))
    def name_for_type_id(unquote(type_id)), do: unquote(type_name)
  end

  def name_for_type_id(_), do: :unknown
end
