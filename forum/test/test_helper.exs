ExUnit.start(capture_log: true)

:net_kernel.start([:"forum@127.0.0.1"])

# Copy the real messaging adapter so tests can stub its transport functions
# (`call/6`, `send/3`) with Mimic instead of a bespoke recording adapter.
Mimic.copy(Forum.Adapter.ErlDist)
