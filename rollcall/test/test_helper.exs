:logger.add_primary_filter(
  :drop_snabbkaffe_trace_points,
  {fn
     %{level: :debug, msg: {:report, %{:"$kind" => _}}}, _extra -> :stop
     _event, _extra -> :ignore
   end, []}
)

# The default library instance. A test that needs other options replaces it.
# See Rollcall.OptionsTest.
{:ok, _pid} = Supervisor.start_link([Rollcall], strategy: :one_for_one, name: Rollcall.TestSupervisor)

ExUnit.start()
