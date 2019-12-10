REPO_DIR=$(shell pwd)

help:
	@echo "\nDOCKER\n"
	@echo "make dev.{dev}        # start docker in foreground"
	@echo "make start.{dev}      # start docker in background"
	@echo "make stop.{dev}       # stop docker"
	@echo "make rebuild.{dev}    # restart docker and force it to rebuild"
	@echo "make pull.{dev}       # pull all the latest docker images"

	@echo "\nTESTS\n"
	@echo "make test.client.{js}            # run client library"
	@echo "make test.server            		# run tests on server"
	@echo "make e2e.{js}             		# run e2e tests with client library"

	@echo "\nHELPERS\n"
	@echo "make clean            # remove all node_modules"
	@echo "make tree             # output a directory tree"


#########################
# Docker 
#########################

dev.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml up

start.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml up -d

stop.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml down  --remove-orphans

rebuild.%:
	make stop.$*
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml build
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml up --force-recreate --build

pull.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml pull

#########################
# TESTS 
#########################

test.client.%:
	cd client/realtime-$* && npm run test:unit

test.server:
	cd server && mix test

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
