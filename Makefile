REPO_DIR=$(shell pwd)

help:
	@echo "\nDOCKER\n"
	@echo "make start{.dev}      # start docker in foreground running Postgres and Realtime"
	@echo "make stop{.dev}       # stop docker (if it is running in the background)"
	@echo "make rebuild{.dev}    # restart docker and force it to rebuild"
	@echo "make pull{.dev}       # pull all the latest docker images"
	@echo "make local:db         # start a Postgres database on port 5432"

	@echo "\nHELPERS\n"
	@echo "make clean            		   # remove all node_modules"
	@echo "make release.github             # create the changelog in https://github.com/supabase/realtime/releases"
	@echo "make release.docker.{tag}       # builds and pushes docker"


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

pull:
	docker-compose pull

pull.%:
	docker-compose -f docker-compose.yml -f docker-compose.$*.yml pull

local\:db:
	docker-compose -f docker-compose.db.yml down 
	docker-compose -f docker-compose.db.yml build 
	docker-compose -f docker-compose.db.yml up --force-recreate


#########################
# Helpers
#########################

clean:
	rm -rf ./node_modules
	rm -rf ./client/realtime-js/node_modules

tree:
	tree -L 2 -I 'README.md|LICENSE|NOTICE|node_modules|Makefile|package*|docker*'

release.github:
	gren changelog --generate --changelog-filename ./CHANGELOG.md --override
	gren release --override

release.docker.%:
	@echo "Did you bump the mix version in ./server first,"
	@echo "and then run mix release?"
	@echo "..."
	@echo "..."
	@echo "..."
	docker build . -t supabase/realtime:$*
	docker push supabase/realtime:$*