REPO_DIR=$(shell pwd)

help:
	@echo "\nDOCKER\n"
	@echo "make dev.{test}        # start docker in foreground"
	@echo "make start.{test}      # start docker in background"
	@echo "make stop.{test}       # stop docker"
	@echo "make rebuild.{test}    # restart docker and force it to rebuild"
	@echo "make pull.{test}       # pull all the latest docker images"

	@echo "\nHELPERS\n"
	@echo "clean            # remove all node_modules"


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
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml down  --remove-orphans
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml build
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml up --force-recreate --build

pull.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml pull

#########################
# Helpers
#########################

clean:
	rm -rf ./node_modules
	rm -rf ./client/realtime-js/node_modules

tree:
	tree -L 2 -I 'README.md|node_modules|cucumber.js|package*|docker*'
