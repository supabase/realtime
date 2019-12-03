# CREDITS
# This file draws heavily from https://github.com/cainophile/pgoutput_decoder
# License: https://github.com/cainophile/pgoutput_decoder/blob/master/LICENSE

# Lifted from epgsql (src/epgsql_binary.erl), this module licensed under
# 3-clause BSD found here: https://raw.githubusercontent.com/epgsql/epgsql/devel/LICENSE

# https://github.com/brianc/node-pg-types/blob/master/lib/builtins.js
# MIT License (MIT)

#  Following query was used to generate this file:
#  SELECT json_object_agg(UPPER(PT.typname), PT.oid::int4 ORDER BY pt.oid)
#  FROM pg_type PT
#  WHERE typnamespace = (SELECT pgn.oid FROM pg_namespace pgn WHERE nspname = 'pg_catalog') -- Take only builting Postgres types with stable OID (extension types are not guaranted to be stable)
#  AND typtype = 'b' -- Only basic types
#  AND typelem = 0 -- Ignore aliases
#  AND typisdefined -- Ignore undefined types



defmodule Realtime.OidDatabase do
  require Logger
  
  defmodule(DataTypes,
    do:
      defstruct(
          types: %{
            16 => "bool",
            17 => "bytea",
            18 => "char",
            20 => "int8",
            21 => "int2",
            23 => "int4",
            24 => "regproc",
            25 => "text",
            26 => "oid",
            27 => "tid",
            28 => "xid",
            29 => "cid",
            114 => "json",
            142 => "xml",
            194 => "pg_node_tree",
            210 => "smgr",
            602 => "path",
            604 => "polygon",
            650 => "cidr",
            700 => "float4",
            701 => "float8",
            702 => "abstime",
            703 => "reltime",
            704 => "tinterval",
            718 => "circle",
            774 => "macaddr8",
            790 => "money",
            829 => "macaddr",
            869 => "inet",
            1033 => "aclitem",
            1042 => "bpchar",
            1043 => "varchar",
            1082 => "date",
            1083 => "time",
            1114 => "timestamp",
            1184 => "timestamptz",
            1186 => "interval",
            1266 => "timetz",
            1560 => "bit",
            1562 => "varbit",
            1700 => "numeric",
            1790 => "refcursor",
            2202 => "regprocedure",
            2203 => "regoper",
            2204 => "regoperator",
            2205 => "regclass",
            2206 => "regtype",
            2950 => "uuid",
            2970 => "txid_snapshot",
            3220 => "pg_lsn",
            3361 => "pg_ndistinct",
            3402 => "pg_dependencies",
            3614 => "tsvector",
            3615 => "tsquery",
            3642 => "gtsvector",
            3734 => "regconfig",
            3769 => "regdictionary",
            3802 => "jsonb",
            4089 => "regnamespace",
            4096 => "regrole"
          } 
      )
  )
  
# Utilises the above %DataTypes{}.types
  def name_for_type_id(type_id) do
    # if type_id is in the above list, get the corresponding name
    if Map.has_key?(%DataTypes{}.types, type_id) do
      %DataTypes{}.types[type_id]
    # else, return the type_id
    else
      type_id
    end
  end

end
