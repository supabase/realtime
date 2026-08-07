#!/bin/bash
set -euo pipefail
set -x
ulimit -n

if [ -n "${RLIMIT_NOFILE:-}" ]; then
    echo "Setting RLIMIT_NOFILE to ${RLIMIT_NOFILE}"
    ulimit -Sn "$RLIMIT_NOFILE"
fi

# Crash dumps are no longer uploaded to S3, but they still need to land
# somewhere writable rather than in the working directory.
export ERL_CRASH_DUMP="${ERL_CRASH_DUMP:-/tmp/erl_crash.dump}"

# Extract a top-level string field from a flat JSON object.
# Handles backslash-escaped characters inside the value.
json_field() {
    awk -v key="$1" '
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

sha256_hex() {
    openssl dgst -sha256 -hex | awk '{print $NF}'
}

# openssl -macopt hexkey: requires a hex-encoded key, so every step of the
# SigV4 key derivation chain stays in hex.
hmac_sha256_hex() {
    openssl dgst -sha256 -mac HMAC -macopt "hexkey:$1" | awk '{print $NF}'
}

# Resolve AWS credentials the same way the SDKs do, in precedence order:
# static environment variables first, then the ECS container credential
# endpoint. Sets aws_access_key / aws_secret_key / aws_session_token in the
# caller's scope.
resolve_aws_credentials() {
    if [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        aws_access_key="$AWS_ACCESS_KEY_ID"
        aws_secret_key="$AWS_SECRET_ACCESS_KEY"
        aws_session_token="${AWS_SESSION_TOKEN:-}"
        return 0
    fi

    : "${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI:?set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or run with an ECS task role}"

    local creds
    creds=$(curl -fsS --retry 3 --retry-connrefused --retry-delay 1 --max-time 10 \
        "http://169.254.170.2${AWS_CONTAINER_CREDENTIALS_RELATIVE_URI}")

    aws_access_key=$(printf '%s' "$creds" | json_field "AccessKeyId")
    aws_secret_key=$(printf '%s' "$creds" | json_field "SecretAccessKey")
    aws_session_token=$(printf '%s' "$creds" | json_field "Token")

    if [[ -z "$aws_access_key" || -z "$aws_secret_key" || -z "$aws_session_token" ]]; then
        echo "Failed to obtain ECS task role credentials" >&2
        return 1
    fi
}

# Fetch the cluster CA from Secrets Manager, signing the request with SigV4.
# Prints the raw SecretString on stdout.
fetch_cluster_secret() {
    : "${CLUSTER_SECRET_ID:?CLUSTER_SECRET_ID is required}"
    : "${CLUSTER_SECRET_REGION:?CLUSTER_SECRET_REGION is required}"

    local aws_access_key aws_secret_key aws_session_token
    resolve_aws_credentials

    local service="secretsmanager"
    local region="${CLUSTER_SECRET_REGION}"
    local host="secretsmanager.${region}.amazonaws.com"
    local amz_target="secretsmanager.GetSecretValue"
    local content_type="application/x-amz-json-1.1"

    # Derive both date forms from a single clock read so they can never
    # disagree across a UTC midnight boundary.
    local amz_date short_date
    amz_date=$(date -u +"%Y%m%dT%H%M%SZ")
    short_date="${amz_date%%T*}"

    local payload payload_hash
    payload=$(printf '{"SecretId":"%s"}' "${CLUSTER_SECRET_ID}")
    payload_hash=$(printf '%s' "$payload" | sha256_hex)

    # SigV4 requires canonical headers sorted by lowercased name; add_header is
    # called in sorted order and builds the canonical block, the signed-header
    # list and the curl arguments together so they can never drift apart.
    local canonical_headers="" signed_headers=""
    local -a curl_headers=()
    add_header() {
        canonical_headers+="${1}:${2}"$'\n'
        [[ -n "$signed_headers" ]] && signed_headers+=";"
        signed_headers+="${1}"
        curl_headers+=(-H "${1}: ${2}")
    }

    add_header "content-type" "$content_type"
    add_header "host" "$host"
    add_header "x-amz-date" "$amz_date"
    # Only present for temporary credentials; static IAM user keys have none.
    [[ -n "$aws_session_token" ]] && add_header "x-amz-security-token" "$aws_session_token"
    add_header "x-amz-target" "$amz_target"

    # METHOD\nURI\nQueryString\nCanonicalHeaders\n\nSignedHeaders\nPayloadHash
    # (canonical_headers already ends in a newline, so the format string's own
    # newline produces the required blank line.)
    local canonical_request canonical_request_hash
    canonical_request=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
        "POST" "/" "" "$canonical_headers" "$signed_headers" "$payload_hash")
    canonical_request_hash=$(printf '%s' "$canonical_request" | sha256_hex)

    local credential_scope="${short_date}/${region}/${service}/aws4_request"
    local string_to_sign
    string_to_sign=$(printf 'AWS4-HMAC-SHA256\n%s\n%s\n%s' \
        "$amz_date" "$credential_scope" "$canonical_request_hash")

    local k_secret_hex k_date k_region k_service k_signing signature
    k_secret_hex=$(printf 'AWS4%s' "$aws_secret_key" | od -An -tx1 -v | tr -d ' \n')
    k_date=$(printf '%s'         "$short_date"     | hmac_sha256_hex "$k_secret_hex")
    k_region=$(printf '%s'       "$region"         | hmac_sha256_hex "$k_date")
    k_service=$(printf '%s'      "$service"        | hmac_sha256_hex "$k_region")
    k_signing=$(printf '%s'      "aws4_request"    | hmac_sha256_hex "$k_service")
    signature=$(printf '%s'      "$string_to_sign" | hmac_sha256_hex "$k_signing")

    local response
    response=$(curl -fsS --retry 3 --retry-connrefused --retry-delay 1 --max-time 15 \
        -X POST "https://${host}/" \
        "${curl_headers[@]}" \
        -H "Authorization: AWS4-HMAC-SHA256 Credential=${aws_access_key}/${credential_scope}, SignedHeaders=${signed_headers}, Signature=${signature}" \
        --data-binary "$payload")

    printf '%s' "$response" | json_field "SecretString"
}

generate_certs() {
    # Never trace this function: it handles AWS credentials and the cluster CA
    # private key, and `set -x` would copy all of them into the container logs.
    set +x
    trap 'set -x' RETURN

    local secret_string
    secret_string=$(fetch_cluster_secret)

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
    rm -f ca.key server.csr

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

# setpriv comes from util-linux, which is already part of the base image, so we
# do not need to ship sudo just to drop privileges. Numeric ids (nobody/nogroup)
# keep this working even on images without a full /etc/passwd.
as_nobody() {
    setpriv --reuid 65534 --regid 65534 --clear-groups "$@"
}

echo "Running migrations"
as_nobody /app/bin/migrate

if [ "${SEED_SELF_HOST-}" = true ]; then
    echo "Seeding selfhosted Realtime"
    as_nobody /app/bin/realtime eval 'Realtime.Release.seeds(Realtime.Repo)'
fi

echo "Starting Realtime"
ulimit -n
exec "$@"
