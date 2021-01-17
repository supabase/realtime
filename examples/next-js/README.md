# Realtime Next.js example

A simple Next.js example which listens to database changes.

## Getting started

1. Install dependencies with `npm install`
2. Start the example database and realtime server with `docker-compose up`
3. Add *.env* file in Next.js example directory with the following DB config env vars:
    * DB_HOST=localhost
    * DB_PORT=5432
    * DB_NAME=postgres
    * DB_USER=postgres
    * DB_PASSWORD=postgres
4. Start app
    * Development mode: `npm run dev`
    * Production mode: `npm run build && npm start`
5. Visit `http://localhost:3000` and you will see the following:

<p align="center"><kbd><img src="./demo.gif" alt="Demo"/></kbd></p>


## Note

This is an example for demo purposes only. There is no auth built into realtime as it is assumed that you will use this behind your own proxy or a internal network.