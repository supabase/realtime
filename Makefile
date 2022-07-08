dev:
	MIX_ENV=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev FLY_REGION=fra FLY_ALLOC_ID=123e4567-e89b-12d3-a456-426614174000 DB_ENC_KEY="1234567890123456" ERL_AFLAGS="-kernel shell_history enabled" iex -S mix phx.server

seed:
	mix run priv/repo/seeds.exs

prod:
	MIX_ENV=prod API_KEY=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev FLY_REGION=fra FLY_ALLOC_ID=123e4567-e89b-12d3-a456-426614174000 DB_ENC_KEY="1234567890123456" ERL_AFLAGS="-kernel shell_history enabled" iex -S mix phx.server

swagger:
	mix phx.swagger.generate

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
