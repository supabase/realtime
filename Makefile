dev:
	MIX_ENV=dev API_KEY=dev SECURE_CHANNELS=true API_JWT_SECRET=dev FLY_REGION=fra DB_ENC_KEY="1234567890123456" ERL_AFLAGS="-kernel shell_history enabled" iex --name realtime@127.0.0.1 -S mix phx.server

prod:
	APP_NAME=realtime SECRET_KEY_BASE=nokey MIX_ENV=prod ERL_AFLAGS="-kernel shell_history enabled" iex -S mix phx.server

swagger:
	mix phx.swagger.generate

#########################
# Docker
#########################

start:
	docker-compose up

start.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml up

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
