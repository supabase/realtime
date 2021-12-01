# Realtime NodeJs example

A simple example which listens to database changes.

## Getting started

1. Spin up database and Realtime server with `docker-compose -f docker-compose.dev.yml up` or `docker-compose -f docker-compose.rls.dev.yml up` in Realtime's root directory
2. Start the NodeJs server using `npm start`
3. Make a change to the Postgres database and the changes will be logged by the NodeJs server 