#!/usr/bin/env bash
# Drive traffic against a deployed heimdall-verify instance and print the
# values you'll paste into compare.sql.
#
# Sentinel caps request bodies at 1 MB (err:user:bad_request:request_body_too_large)
# so ingress is driven via loops of ~1000 KB chunks; egress is one call because
# response bodies aren't capped.
#
# Usage:
#   ./drive.sh <URL> [ingress_mb] [egress_mb] [echo_mb]
#   URL=https://foo.unkey.app ./drive.sh
#
# Defaults: 200 MB ingress, 500 MB egress, 50 MB echo.

set -euo pipefail

URL="${1:-${URL:-}}"
INGRESS_MB="${2:-${INGRESS_MB:-50}}"
EGRESS_MB="${3:-${EGRESS_MB:-200}}"
ECHO_MB="${4:-${ECHO_MB:-20}}"
# Per-request pacing (seconds). HTTP/2 to sentinel can get stream-reset
# under burst load; a small gap keeps the upstream happy.
SLEEP_MS="${SLEEP_MS:-1500}"

if [[ -z "$URL" ]]; then
  echo "usage: $0 <URL> [ingress_mb] [egress_mb] [echo_mb]" >&2
  exit 1
fi
URL="${URL%/}"

for cmd in curl jq dd; do
  command -v "$cmd" >/dev/null || { echo "need $cmd in PATH" >&2; exit 1; }
done

hdr() { printf "\n\033[1;36m=== %s ===\033[0m\n" "$*"; }
say() { printf "  %s\n" "$*"; }

hdr "target"
say "URL        = $URL"
say "ingress    = ${INGRESS_MB} MB (loops of ~1000 KB due to sentinel 1 MB request body cap)"
say "egress     = ${EGRESS_MB} MB (single response)"
say "echo       = ${ECHO_MB} MB (loops of ~1000 KB)"

hdr "warmup (Unkey Deploy scale-to-zero cold start can 504 the first ~3 calls)"
for i in $(seq 1 10); do
  CODE=$(curl -sS -o /dev/null -w "%{http_code}" --max-time 15 "$URL/healthz" || echo "000")
  say "attempt $i: $CODE"
  if [[ "$CODE" == "200" ]]; then
    break
  fi
  sleep 1
done

hdr "reset"
curl -sSf --http1.1 --retry 5 --retry-all-errors --retry-delay 1 --max-time 60 -XPOST "$URL/reset" -o /dev/null && say "ledger cleared"

hdr "info"
INFO=$(curl -sSf --http1.1 --retry 5 --retry-all-errors --retry-delay 1 --max-time 60 "$URL/info")
echo "$INFO" | jq .
POD_UID=$(echo "$INFO" | jq -r '.pod_uid')
POD_NAME=$(echo "$INFO" | jq -r '.pod_name')
NODE_NAME=$(echo "$INFO" | jq -r '.node_name')
# Unkey Deploy intentionally doesn't expose downward API to user pods, so
# these will be empty. We fall back to DEPLOYMENT_ID env var (set via the
# Unkey dashboard URL path or API) for CH filtering.
DEPLOYMENT_ID="${DEPLOYMENT_ID:-}"

# Capture wall time window for the CH query. Both are Unix ms, same format
# as the app's ts_ms so they can be pasted straight into compare.sql.
START_TS_MS=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || \
              node -e 'console.log(Date.now())' 2>/dev/null || \
              date +%s%3N)

hdr "drive ingress (${INGRESS_MB} x ~1 MB POSTs, ${SLEEP_MS}ms gap)"
for i in $(seq 1 "$INGRESS_MB"); do
  dd if=/dev/zero bs=1000K count=1 2>/dev/null | \
    curl -sSf --http1.1 --retry 5 --retry-all-errors --retry-delay 1 --max-time 60 --data-binary @- -H "Content-Type: application/octet-stream" \
      "$URL/ingress" > /dev/null
  if (( i % 10 == 0 )); then printf "."; fi
  sleep "$(awk -v ms="$SLEEP_MS" 'BEGIN {print ms/1000}')"
done
echo ""

hdr "drive egress (single GET, ${EGRESS_MB} MB response)"
EGRESS_BYTES=$(( EGRESS_MB * 1024 * 1024 ))
curl -sSf --http1.1 --retry 5 --retry-all-errors --retry-delay 1 --max-time 60 -o /dev/null "${URL}/egress?bytes=${EGRESS_BYTES}"
say "done"

hdr "drive echo (${ECHO_MB} x ~1 MB roundtrips, ${SLEEP_MS}ms gap)"
for i in $(seq 1 "$ECHO_MB"); do
  head -c 1000000 /dev/urandom | \
    curl -sSf --http1.1 --retry 5 --retry-all-errors --retry-delay 1 --max-time 60 --data-binary @- -o /dev/null "$URL/echo"
  if (( i % 5 == 0 )); then printf "."; fi
  sleep "$(awk -v ms="$SLEEP_MS" 'BEGIN {print ms/1000}')"
done
echo ""

END_TS_MS=$(python3 -c 'import time; print(int(time.time()*1000))' 2>/dev/null || \
            node -e 'console.log(Date.now())' 2>/dev/null || \
            date +%s%3N)

hdr "app-side stats"
STATS=$(curl -sSf --http1.1 --retry 5 --retry-all-errors --retry-delay 1 --max-time 60 "$URL/stats")
echo "$STATS" | jq .
APP_IN=$(echo "$STATS" | jq -r '.ingress_bytes')
APP_EG=$(echo "$STATS" | jq -r '.egress_bytes')
LEDGER_FIRST=$(echo "$STATS" | jq -r '.first_ts_ms')
LEDGER_LAST=$(echo "$STATS" | jq -r '.last_ts_ms')

hdr "next step"
# Unkey Deploy doesn't leak pod_uid to user code. We key on resource_id
# (= unkey.com/deployment.id label). Grab deployment_id from the Unkey
# dashboard URL for this project and set DEPLOYMENT_ID before re-running,
# or substitute it manually into the SQL below.
if [[ -z "$DEPLOYMENT_ID" ]]; then
  FILTER="-- TODO: set DEPLOYMENT_ID env var or paste the ID below
  WHERE resource_id = 'dep_REPLACE_ME'"
else
  FILTER="WHERE resource_id = '${DEPLOYMENT_ID}'"
fi

cat <<EOF
Wait ~30s for heimdall to flush checkpoints, then run this in ClickHouse:

  SELECT
    resource_id,
    pod_uid,
    count() AS rows,
    (max(ts) - min(ts)) / 1000.0 AS window_s,
    (max(network_ingress_public_bytes) + max(network_ingress_private_bytes))
      - (min(network_ingress_public_bytes) + min(network_ingress_private_bytes)) AS ch_ingress,
    (max(network_egress_public_bytes) + max(network_egress_private_bytes))
      - (min(network_egress_public_bytes) + min(network_egress_private_bytes)) AS ch_egress
  FROM default.instance_checkpoints
  ${FILTER}
    AND ts >= ${START_TS_MS}
    AND ts <= ${END_TS_MS}
  GROUP BY resource_id, pod_uid;

Compare against app-side:
  app_ingress = ${APP_IN} bytes
  app_egress  = ${APP_EG} bytes

Healthy: ch_ingress and ch_egress are 1.00x - 1.30x the app values.
EOF
