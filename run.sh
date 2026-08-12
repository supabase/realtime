#!/bin/bash
set -euo pipefail
set -x
ulimit -n

if [ -n "${RLIMIT_NOFILE:-}" ]; then
    echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
    ulimit -Sn "$RLIMIT_NOFILE"
fi

write_cluster_ca() {
    set +x
    trap 'set -x' RETURN

    : "${CLUSTER_SECRET_ID:?CLUSTER_SECRET_ID is required}"
    : "${CLUSTER_SECRET_REGION:?CLUSTER_SECRET_REGION is required}"

    local secret
    secret=$(AWS_REGION="$CLUSTER_SECRET_REGION" \
        awslim secretsmanager get-secret-value "{SecretId:\"${CLUSTER_SECRET_ID}\"}" \
        --query SecretString --raw-output)

    printf '%s' "$secret" | jq -er '.key'  | base64 -d > ca.key
    printf '%s' "$secret" | jq -er '.cert' | base64 -d > ca.cert
}

generate_certs() {
    write_cluster_ca

    openssl req -new -nodes -out server.csr -keyout server.key \
        -subj "/C=US/ST=Delaware/L=New Castle/O=Supabase Inc/CN=$(hostname -f)"
    openssl x509 -req -in server.csr -days 90 -CA ca.cert -CAkey ca.key -out server.cert
    rm -f ca.key server.csr

    export GEN_RPC_CACERTFILE="$PWD/ca.cert"
    export GEN_RPC_KEYFILE="$PWD/server.key"
    export GEN_RPC_CERTFILE="$PWD/server.cert"
    chmod a+r "$GEN_RPC_CACERTFILE" "$GEN_RPC_KEYFILE" "$GEN_RPC_CERTFILE"

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
    export ERL_AFLAGS="${ERL_AFLAGS:-} -proto_dist inet_tls -ssl_dist_optfile ${PWD}/inet_tls.conf"
}

as_nobody() {
    setpriv --reuid 65534 --regid 65534 --clear-groups "$@"
}

if [[ -n "${GENERATE_CLUSTER_CERTS:-}" ]]; then
    generate_certs
fi

echo "Running migrations"
as_nobody /app/bin/migrate

if [ "${SEED_SELF_HOST-}" = true ]; then
    echo "Seeding selfhosted Realtime"
    as_nobody /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)'
fi

echo "Starting Realtime"
ulimit -n
exec "$@"
