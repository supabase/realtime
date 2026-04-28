#!/bin/bash
set -euo pipefail
set -x
ulimit -n

if [ ! -z "${RLIMIT_NOFILE:-}" ]; then
    echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
    ulimit -Sn "$RLIMIT_NOFILE"
fi


generate_certs() {
    : "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:?AWS_CONTAINER_CREDENTIALS_RELATIVE_URI is required}"
    : "${CLUSTER_SECRET_ID:?CLUSTER_SECRET_ID is required}"
    : "${CLUSTER_SECRET_REGION:?CLUSTER_SECRET_REGION is required}"

    local creds
    creds=$(curl -fsS "http://169.254.170.2${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}")

    # Extract a top-level string field from a flat JSON object.
    # Handles backslash-escaped characters inside the value.
    json_field() {
        local field="$1"
        awk -v key="$field" '
            BEGIN { RS="\0" }
            {
                pat = "\"" key "\"[[:space:]]*:[[:space:]]*\""
                if (match($0, pat)) {
                    s = substr($0, RSTART + RLENGTH)
                    out = ""
                    i = 1
                    while (i <= length(s)) {
                        c = substr(s, i, 1)
                        if (c == "\\") { out = out substr(s, i, 2); i += 2; continue }
                        if (c == "\"") { break }
                        out = out c
                        i++
                    }
                    gsub(/\\"/, "\"", out)
                    gsub(/\\\\/, "\\", out)
                    gsub(/\\n/,  "\n", out)
                    gsub(/\\t/,  "\t", out)
                    gsub(/\\r/,  "\r", out)
                    gsub(/\\\//, "/",  out)
                    print out
                }
            }
        '
    }

    local aws_access_key aws_secret_key aws_session_token
    aws_access_key=$(printf '%s' "$creds" | json_field "AccessKeyId")
    aws_secret_key=$(printf '%s' "$creds" | json_field "SecretAccessKey")
    aws_session_token=$(printf '%s' "$creds" | json_field "Token")

    if [[ -z "$aws_access_key" || -z "$aws_secret_key" || -z "$aws_session_token" ]]; then
        echo "Failed to obtain ECS task role credentials" >&2
        return 1
    fi

    local service="secretsmanager"
    local region="${CLUSTER_SECRET_REGION}"
    local host="secretsmanager.${region}.amazonaws.com"
    local endpoint="https://${host}/"
    local amz_target="secretsmanager.GetSecretValue"
    local content_type="application/x-amz-json-1.1"
    local amz_date short_date
    amz_date=$(date -u +"%Y%m%dT%H%M%SZ")
    short_date=$(date -u +"%Y%m%d")

    local payload
    payload=$(printf '{"SecretId":"%s"}' "${CLUSTER_SECRET_ID}")

    sha256_hex() {
        openssl dgst -sha256 -hex | awk '{print $NF}'
    }

    local payload_hash
    payload_hash=$(printf '%s' "$payload" | sha256_hex)

    # Canonical headers must be sorted alphabetically by lowercased name.
    # Format per AWS SigV4 spec: METHOD\nURI\nQueryString\nHeaders\n\nSignedHeaders\nPayloadHash
    local signed_headers="content-type;host;x-amz-date;x-amz-security-token;x-amz-target"
    local canonical_request
    canonical_request=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n\n%s\n%s' \
        "POST" \
        "/" \
        "" \
        "content-type:${content_type}" \
        "host:${host}" \
        "x-amz-date:${amz_date}" \
        "x-amz-security-token:${aws_session_token}" \
        "x-amz-target:${amz_target}" \
        "${signed_headers}" \
        "${payload_hash}")

    local canonical_request_hash
    canonical_request_hash=$(printf '%s' "$canonical_request" | sha256_hex)

    local credential_scope="${short_date}/${region}/${service}/aws4_request"
    local string_to_sign
    string_to_sign=$(printf 'AWS4-HMAC-SHA256\n%s\n%s\n%s' \
        "$amz_date" "$credential_scope" "$canonical_request_hash")

    # Derive signing key via successive HMAC-SHA256 steps.
    # openssl -macopt hexkey: requires hex input, so we hex-encode the initial key with od.
    hmac_sha256_hex() {
        openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" | awk '{print $NF}'
    }

    local k_secret_hex k_date k_region k_service k_signing signature
    k_secret_hex=$(printf 'AWS4%s' "$aws_secret_key" | od -An -tx1 -v | tr -d ' \n')
    k_date=$(printf '%s'        "$short_date"    | hmac_sha256_hex "$k_secret_hex")
    k_region=$(printf '%s'      "$region"        | hmac_sha256_hex "$k_date")
    k_service=$(printf '%s'     "$service"       | hmac_sha256_hex "$k_region")
    k_signing=$(printf '%s'     "aws4_request"   | hmac_sha256_hex "$k_service")
    signature=$(printf '%s'     "$string_to_sign" | hmac_sha256_hex "$k_signing")

    local authorization="AWS4-HMAC-SHA256 Credential=${aws_access_key}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}"

    local response
    response=$(curl -fsS -X POST "$endpoint" \
        -H "Content-Type: ${content_type}" \
        -H "Host: ${host}" \
        -H "X-Amz-Date: ${amz_date}" \
        -H "X-Amz-Security-Token: ${aws_session_token}" \
        -H "X-Amz-Target: ${amz_target}" \
        -H "Authorization: ${authorization}" \
        --data-binary "$payload")

    local secret_string
    secret_string=$(printf '%s' "$response" | json_field "SecretString")

    if [[ -z "$secret_string" ]]; then
        echo "SecretString not found in Secrets Manager response" >&2
        return 1
    fi

    printf '%s' "$secret_string" | json_field "key"  | base64 -d > ca.key
    printf '%s' "$secret_string" | json_field "cert" | base64 -d > ca.cert

    if [[ ! -s ca.key || ! -s ca.cert ]]; then
        echo "Failed to extract ca.key/ca.cert from secret" >&2
        return 1
    fi

    openssl req -new -nodes -out server.csr -keyout server.key \
        -subj "/C=US/ST=Delaware/L=New Castle/O=Supabase Inc/CN=$(hostname -f)"
    openssl x509 -req -in server.csr -days 90 -CA ca.cert -CAkey ca.key -out server.cert
    rm -f ca.key

    local CWD
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
    export ERL_AFLAGS="${ERL_AFLAGS:-} -proto_dist inet_tls -ssl_dist_optfile ${CWD}/inet_tls.conf"
}


if [[ -n "${GENERATE_CLUSTER_CERTS:-}" ]] ; then
    generate_certs
fi

echo "Running migrations"
sudo -E -u nobody /app/bin/migrate

if [ "${SEED_SELF_HOST-}" = true ]; then
    echo "Seeding selfhosted Realtime"
    sudo -E -u nobody /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)'
fi

echo "Starting Realtime"
ulimit -n
exec "$@"
