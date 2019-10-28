# Supabase Realtime

> Status: ALPHA
>
> This repo hasn't yet implemented Socket Authentication so it is not recommended for use in production

Listens to changes in a PostgreSQL Database and broadcasts them over websockets.

## Docs 

To see the full docs, go to [https://supabase.io/docs/realtime/getting-started](https://supabase.io/docs/realtime/getting-started)

## Getting started


The easiest way to use this is to set up a docker compose:

```sh 
# docker-compose.yml
version: '3'
services:
  realtime:
    image: supabase/realtime
    ports:
      - "4000:4000"
    environment:
    - POSTGRES_USER=postgres
    - POSTGRES_PASSWORD=postgres
    - POSTGRES_DB=postgres
    - POSTGRES_HOST=localhost
    - POSTGRES_PORT=5432
```

Then run:

```sh
docker-compose up     # Run in foreground on port 4000
```

## Contributing

We welcome any issues, pull requests, and feedback. See [https://supabase.io/docs/-/contributing](https://supabase.io/docs/-/contributing) for more details.


**Credits**

- [https://github.com/cainophile/cainophile](https://github.com/cainophile/cainophile) - A lot of this implementation leveraged the work already done on Canophile.
