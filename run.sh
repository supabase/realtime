#!/bin/bash
set -euo pipefail
set -x
ulimit -n

if [ -n "${RLIMIT_NOFILE:-}" ]; then
    echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
    ulimit -Sn "$RLIMIT_NOFILE"
fi

generate_certs() {
    aws secretsmanager get-secret-value --secret-id "${CLUSTER_SECRET_ID}" --region "${CLUSTER_SECRET_REGION}" | jq -r '.SecretString' > cert_secrets
    jq -r '.key' cert_secrets | base64 -d > ca.key
    jq -r '.cert' cert_secrets | base64 -d > ca.cert
    openssl req -new -nodes -out server.csr -keyout server.key -subj "/C=US/ST=Delaware/L=New Castle/O=Supabase Inc/CN=$(hostname -f)"
    openssl x509 -req -in server.csr -days 90 -CA ca.cert -CAkey ca.key -out server.cert
    rm -f ca.key
    CWD=$(pwd)
    export GEN_RPC_CACERTFILE="$CWD/ca.cert"
    export GEN_RPC_KEYFILE="$CWD/server.key"
    export GEN_RPC_CERTFILE="$CWD/server.cert"
    chmod a+r "$GEN_RPC_CACERTFILE"
    chmod a+r "$GEN_RPC_KEYFILE"
    chmod a+r "$GEN_RPC_CERTFILE"
    cat > inet_tls.conf <<EOF
[
  {server, [
    {certfile, "${GEN_RPC_CERTFILE}"},
    {keyfile, "${GEN_RPC_KEYFILE}"},
    {secure_renegotiate, true}
  ]},
  {client, [
    {cacertfile, "${GEN_RPC_CACERTFILE}"},
    {verify, verify_none},
    {secure_renegotiate, true}
  ]}
].
EOF
    export ERL_AFLAGS="${ERL_AFLAGS} -proto_dist inet_tls -ssl_dist_optfile ${CWD}/inet_tls.conf"
}

if [[ -n "${GENERATE_CLUSTER_CERTS:-}" ]] ; then
    generate_certs
fi

echo "Running migrations"
/app/bin/migrate

if [ "${SEED_SELF_HOST-}" = true ]; then
    echo "Seeding selfhosted Realtime"
    /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)'
fi

echo "Starting Realtime"
ulimit -n
exec "$@"
