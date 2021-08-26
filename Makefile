dev:
	MIX_ENV=dev ERL_AFLAGS="-kernel shell_history enabled" iex -S mix phx.server

prod:
	FLY_APP_NAME=m SECRET_KEY_BASE=nokey MIX_ENV=prod ERL_AFLAGS="-kernel shell_history enabled" iex -S mix phx.server
