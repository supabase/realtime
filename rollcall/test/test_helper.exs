:logger.add_primary_filter(
  :drop_snabbkaffe_trace_points,
  {fn
     %{level: :debug, msg: {:report, %{:"$kind" => _}}}, _extra -> :stop
     _event, _extra -> :ignore
   end, []}
)

ExUnit.start()
