.PHONY: dev dev.orange seed prod bench.% dev_db start start.% stop stop.% rebuild rebuild.%

dev:
	SLOT_NAME_SUFFIX=some_sha PORT=4000 MIX_ENV=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev FLY_REGION=fra FLY_ALLOC_ID=123e4567-e89b-12d3-a456-426614174000 DB_ENC_KEY="1234567890123456" ERL_AFLAGS="-kernel shell_history enabled" iex --name pink@127.0.0.1 --cookie cookie  -S mix phx.server

dev.orange:
	SLOT_NAME_SUFFIX=some_sha PORT=4001 MIX_ENV=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev FLY_REGION=fra FLY_ALLOC_ID=123e4567-e89b-12d3-a456-426614174000 DB_ENC_KEY="1234567890123456" ERL_AFLAGS="-kernel shell_history enabled" iex --name orange@127.0.0.1 --cookie cookie  -S mix phx.server

seed:
	mix run priv/repo/seeds.exs

prod:
	SLOT_NAME_SUFFIX=some_sha MIX_ENV=prod FLY_APP_NAME=realtime-local API_KEY=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev FLY_REGION=fra FLY_ALLOC_ID=123e4567-e89b-12d3-a456-426614174000 DB_ENC_KEY="1234567890123456" SECRET_KEY_BASE=M+55t7f6L9VWyhH03R5N7cIhrdRlZaMDfTE6Udz0eZS7gCbnoLQ8PImxwhEyao6D DASHBOARD_USER=realtime_local DASHBOARD_PASSWORD=password ERL_AFLAGS="-kernel shell_history enabled" iex -S mix phx.server

bench.%:
	SLOT_NAME_SUFFIX=some_sha MIX_ENV=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev FLY_REGION=fra FLY_ALLOC_ID=123e4567-e89b-12d3-a456-426614174000 DB_ENC_KEY="1234567890123456" ERL_AFLAGS="-kernel shell_history enabled" mix run bench/$*

dev_db:
	docker-compose -f docker-compose.dbs.yml up -d && mix ecto.migrate --log-migrator-sql
#########################
# Docker
#########################

start:
	docker-compose up

start.%:
	docker-compose -f docker-compose.$*.yml up

stop:
	docker-compose down --remove-orphans

stop.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml down  --remove-orphans

rebuild:
	make stop
	docker-compose build
	docker-compose up --force-recreate --build

rebuild.%:
	make stop.$*
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml build
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml up --force-recreate --build
