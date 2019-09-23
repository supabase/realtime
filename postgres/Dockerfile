FROM postgres:11-alpine AS builder

RUN apk add --no-cache build-base git
RUN git clone https://github.com/eulerto/wal2json.git
WORKDIR wal2json
RUN USE_PGXS=1 make && make install

FROM postgres:11-alpine
COPY --from=builder /wal2json/wal2json.so /usr/local/lib/postgresql/

ADD ./mnt /docker-entrypoint-initdb.d/