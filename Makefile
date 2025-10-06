CLUSTER_STRATEGIES ?= EPMD
NODE_NAME ?= pink
PORT ?= 4000

.PHONY: dev dev.orange seed prod bench.% dev_db start start.% stop stop.% rebuild rebuild.%

.DEFAULT_GOAL := help

# Common commands

dev: ## Start a dev server
	ELIXIR_ERL_OPTIONS="+hmax 1000000000" SLOT_NAME_SUFFIX=some_sha PORT=$(PORT) MIX_ENV=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev REGION=us-east-1 DB_ENC_KEY="1234567890123456" CLUSTER_STRATEGIES=$(CLUSTER_STRATEGIES) ERL_AFLAGS="-kernel shell_history enabled" GEN_RPC_TCP_SERVER_PORT=5369 GEN_RPC_TCP_CLIENT_PORT=5469 iex --name $(NODE_NAME)@127.0.0.1 --cookie cookie  -S mix phx.server

dev.orange: ## Start another dev server (orange) on port 4001
	ELIXIR_ERL_OPTIONS="+hmax 1000000000" SLOT_NAME_SUFFIX=some_sha PORT=4001 MIX_ENV=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev REGION=eu-west-1 DB_ENC_KEY="1234567890123456" CLUSTER_STRATEGIES=$(CLUSTER_STRATEGIES) ERL_AFLAGS="-kernel shell_history enabled" GEN_RPC_TCP_SERVER_PORT=5469 GEN_RPC_TCP_CLIENT_PORT=5369 iex --name orange@127.0.0.1 --cookie cookie  -S mix phx.server

seed: ## Seed the database
	DB_ENC_KEY="1234567890123456" FLY_ALLOC_ID=123e4567-e89b-12d3-a456-426614174000 mix run priv/repo/dev_seeds.exs

prod: ## Start a server with a MIX_ENV=prod
	ELIXIR_ERL_OPTIONS="+hmax 1000000000" SLOT_NAME_SUFFIX=some_sha MIX_ENV=prod FLY_APP_NAME=realtime-local API_KEY=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev FLY_REGION=fra FLY_ALLOC_ID=123e4567-e89b-12d3-a456-426614174000 DB_ENC_KEY="1234567890123456" SECRET_KEY_BASE=M+55t7f6L9VWyhH03R5N7cIhrdRlZaMDfTE6Udz0eZS7gCbnoLQ8PImxwhEyao6D DASHBOARD_USER=realtime_local DASHBOARD_PASSWORD=password ERL_AFLAGS="-kernel shell_history enabled" iex -S mix phx.server

bench.%: ## Run benchmark with a specific file. e.g. bench.secrets
	ELIXIR_ERL_OPTIONS="+hmax 1000000000" SLOT_NAME_SUFFIX=some_sha MIX_ENV=dev SECURE_CHANNELS=true API_JWT_SECRET=dev METRICS_JWT_SECRET=dev FLY_REGION=fra FLY_ALLOC_ID=123e4567-e89b-12d3-a456-426614174000 DB_ENC_KEY="1234567890123456" ERL_AFLAGS="-kernel shell_history enabled" mix run bench/$*

dev_db: ## Start dev databases using docker
	docker-compose -f docker-compose.dbs.yml up -d && mix ecto.migrate --log-migrator-sql

# Docker specific commands

start: ## Start main docker compose
	docker-compose up

start.%: ## Start docker compose with a specific file. e.g. start.dbs
	docker-compose -f docker-compose.$*.yml up

stop: ## Stop main docker compose
	docker-compose down --remove-orphans

stop.%: ## Stop docker compose with a specific file. e.g. stop.dbs
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml down  --remove-orphans

rebuild: ## Rebuild main docker compose images
	make stop
	docker-compose build
	docker-compose up --force-recreate --build

rebuild.%: ## Rebuild docker compose images with a specific file. e.g. rebuild.dbs
	make stop.$*
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml build
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml up --force-recreate --build

# Based on https://gist.github.com/prwhite/8168133
.DEFAULT_GOAL:=help
.PHONY: help
help:  ## Display this help
		$(info Realtime commands)
		@awk 'BEGIN {FS = ":.*##"; printf "\nUsage:\n  make \033[36m<target>\033[0m\n"} /^[%.a-zA-Z0-9_-]+:.*?##/ { printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5) } ' $(MAKEFILE_LIST)
