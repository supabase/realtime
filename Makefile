dev:
	MIX_ENV=dev ERL_AFLAGS="-kernel shell_history enabled" iex -S mix phx.server
