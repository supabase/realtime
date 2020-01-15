REPO_DIR=$(shell pwd)

help:
	@echo "\nDOCKER\n"
	@echo "make start.{dev}      # start docker in foreground running Postgres and Realtime"
	@echo "make stop.{dev}       # stop docker (if it is running in the background)"
	@echo "make rebuild.{dev}    # restart docker and force it to rebuild"
	@echo "make pull.{dev}       # pull all the latest docker images"
	@echo "make local:db         # start a Postgres database on port 5432"

	@echo "\nGOOGLE RUN\n"
	@echo "make deploy           # deploys Realtime docker image to Google Cloud Run"

	@echo "\nTESTS\n"
	@echo "make test.client.{js}    # run client library"
	@echo "make test.server         # run tests on server"
	@echo "make e2e.{js}            # run e2e tests with client library"

	@echo "\nHELPERS\n"
	@echo "make clean            # remove all node_modules"
	@echo "make tree             # output a directory tree"


#########################
# Docker 
#########################

local\:db:
	docker-compose -f docker-compose.db.yml down 
	docker-compose -f docker-compose.db.yml build 
	docker-compose -f docker-compose.db.yml up --force-recreate

start.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml up 

stop.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml down  --remove-orphans

rebuild.%:
	make stop.$*
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml build
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml up --force-recreate --build

pull.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml pull


#########################
# Google Run 
#########################

PROJECT_ID := $(shell gcloud config get-value project)
deploy:
	gcloud builds submit --tag gcr.io/$(PROJECT_ID)/realtime

#########################
# TESTS 
#########################

test.client.%:
	cd client/realtime-$* && npm run test:unit

test.server:
	docker-compose -f docker-compose.yml -f docker-compose.test.yml build
	docker-compose -f docker-compose.yml -f docker-compose.test.yml run --rm realtime

e2e.%:
	cd client/realtime-$* && npm run test:e2e

#########################
# Helpers
#########################

clean:
	rm -rf ./node_modules
	rm -rf ./client/realtime-js/node_modules

tree:
	tree -L 2 -I 'README.md|LICENSE|NOTICE|node_modules|Makefile|package*|docker*'
