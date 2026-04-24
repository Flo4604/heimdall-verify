-- Compare heimdall-verify's application-layer ledger against what heimdall's
-- eBPF counters wrote into ClickHouse for the same pod.
--
-- Inputs to set before running (replace placeholders via :variable or edit):
--   pod_uid  (string)  from curl .../info -> .pod_uid
--   first_ts (Int64)   from curl .../stats -> .first_ts_ms
--   last_ts  (Int64)   from curl .../stats -> .last_ts_ms
--
-- Quick flow:
--   1. kubectl -n heimdall-verify exec deploy/heimdall-verify -- wget -qO- localhost:8080/reset
--   2. Drive traffic (see suggested curl commands at bottom of this file).
--   3. curl .../stats          -> grab app_ingress, app_egress, first/last ts
--   4. Paste those + pod_uid into the queries below and run against CH.
--
-- Expected healthy result: eBPF numbers are 5-30% higher than app numbers due
-- to TCP/IP/HTTP/probe overhead. Numbers significantly lower = missing attach.
-- Numbers 2x+ higher with no traffic explains itself = probe/DNS chatter.

-- =============================================================================
-- 1. Totals over the test window
-- =============================================================================
-- Single row; eyeball against curl .../stats
SELECT
  pod_uid,
  count() AS checkpoint_rows,
  min(ts) AS first_ts_ms,
  max(ts) AS last_ts_ms,
  (max(ts) - min(ts)) / 1000.0 AS window_seconds,

  -- Ingress: public + private summed.
  (max(network_ingress_public_bytes) + max(network_ingress_private_bytes))
    - (min(network_ingress_public_bytes) + min(network_ingress_private_bytes))
    AS ch_ingress_bytes,
  max(network_ingress_public_bytes)  - min(network_ingress_public_bytes)  AS ch_ingress_public_bytes,
  max(network_ingress_private_bytes) - min(network_ingress_private_bytes) AS ch_ingress_private_bytes,

  -- Egress: public + private summed.
  (max(network_egress_public_bytes) + max(network_egress_private_bytes))
    - (min(network_egress_public_bytes) + min(network_egress_private_bytes))
    AS ch_egress_bytes,
  max(network_egress_public_bytes)  - min(network_egress_public_bytes)  AS ch_egress_public_bytes,
  max(network_egress_private_bytes) - min(network_egress_private_bytes) AS ch_egress_private_bytes
FROM default.instance_checkpoints
WHERE pod_uid = 'REPLACE_POD_UID'
  AND ts >= REPLACE_FIRST_TS_MS
  AND ts <= REPLACE_LAST_TS_MS
GROUP BY pod_uid;

-- =============================================================================
-- 2. Per-minute breakdown (sanity-check alignment over time)
-- =============================================================================
SELECT
  toStartOfMinute(toDateTime(toInt64(ts / 1000))) AS minute,
  count() AS rows,
  max(network_ingress_public_bytes + network_ingress_private_bytes)
    - min(network_ingress_public_bytes + network_ingress_private_bytes) AS ch_ingress_bytes,
  max(network_egress_public_bytes + network_egress_private_bytes)
    - min(network_egress_public_bytes + network_egress_private_bytes) AS ch_egress_bytes
FROM default.instance_checkpoints
WHERE pod_uid = 'REPLACE_POD_UID'
  AND ts >= REPLACE_FIRST_TS_MS
  AND ts <= REPLACE_LAST_TS_MS
GROUP BY minute
ORDER BY minute;

-- =============================================================================
-- 3. Side-by-side with the app ledger (CH pulls the ledger over HTTP)
-- =============================================================================
-- Requires ClickHouse to be able to reach the verify Service. Adjust the URL
-- host/port to whatever works from inside the CH cluster (a ClusterIP
-- service DNS name, or a port-forwarded address).
--
-- If CH can't reach the pod, curl the CSV locally and load it:
--   curl -s http://<pod>:8080/ledger.csv > /tmp/ledger.csv
--   kubectl cp /tmp/ledger.csv clickhouse-0:/tmp/ledger.csv -n <ns>
--   kubectl exec -n <ns> clickhouse-0 -- clickhouse-client --query \
--     "CREATE TEMPORARY TABLE ledger (ts_ms Int64, dir String, bytes Int64, path String) ENGINE = Memory;
--      INSERT INTO ledger FORMAT CSVWithNames" < /tmp/ledger.csv
--   -- then run step 4 below against the temp table.

WITH app AS (
  SELECT
    toStartOfMinute(toDateTime(toInt64(ts_ms / 1000))) AS minute,
    sumIf(bytes, dir = 'ingress') AS app_ingress,
    sumIf(bytes, dir = 'egress')  AS app_egress
  FROM url(
    'http://heimdall-verify.heimdall-verify.svc.cluster.local/ledger.csv',
    CSVWithNames,
    'ts_ms Int64, dir String, bytes Int64, path String'
  )
  GROUP BY minute
),
ch AS (
  SELECT
    toStartOfMinute(toDateTime(toInt64(ts / 1000))) AS minute,
    max(network_ingress_public_bytes + network_ingress_private_bytes)
      - min(network_ingress_public_bytes + network_ingress_private_bytes) AS ch_ingress,
    max(network_egress_public_bytes + network_egress_private_bytes)
      - min(network_egress_public_bytes + network_egress_private_bytes) AS ch_egress
  FROM default.instance_checkpoints
  WHERE pod_uid = 'REPLACE_POD_UID'
    AND ts >= REPLACE_FIRST_TS_MS
    AND ts <= REPLACE_LAST_TS_MS
  GROUP BY minute
)
SELECT
  coalesce(app.minute, ch.minute) AS minute,
  app.app_ingress,
  ch.ch_ingress,
  ch.ch_ingress - app.app_ingress AS ingress_overhead_bytes,
  round(ch.ch_ingress / nullIf(app.app_ingress, 0), 3) AS ingress_ratio,
  app.app_egress,
  ch.ch_egress,
  ch.ch_egress - app.app_egress AS egress_overhead_bytes,
  round(ch.ch_egress / nullIf(app.app_egress, 0), 3) AS egress_ratio
FROM app
FULL OUTER JOIN ch ON app.minute = ch.minute
ORDER BY minute;

-- =============================================================================
-- 4. Totals comparison (after loading ledger into a temp table, step 3 fallback)
-- =============================================================================
-- SELECT
--   (SELECT sumIf(bytes, dir = 'ingress') FROM ledger) AS app_ingress,
--   (SELECT sumIf(bytes, dir = 'egress')  FROM ledger) AS app_egress,
--   (SELECT (max(network_ingress_public_bytes + network_ingress_private_bytes)
--          - min(network_ingress_public_bytes + network_ingress_private_bytes))
--    FROM default.instance_checkpoints
--    WHERE pod_uid = 'REPLACE_POD_UID') AS ch_ingress,
--   (SELECT (max(network_egress_public_bytes + network_egress_private_bytes)
--          - min(network_egress_public_bytes + network_egress_private_bytes))
--    FROM default.instance_checkpoints
--    WHERE pod_uid = 'REPLACE_POD_UID') AS ch_egress;

-- =============================================================================
-- Suggested curl recipes to drive traffic
-- =============================================================================
-- # Reset the ledger
-- curl -XPOST http://HOST:8080/reset
--
-- # Send 10 MB of ingress (app records 10485760)
-- dd if=/dev/zero bs=1M count=10 2>/dev/null | curl --data-binary @- http://HOST:8080/ingress
--
-- # Pull 50 MB of egress (app records 52428800)
-- curl -o /dev/null 'http://HOST:8080/egress?bytes=52428800'
--
-- # Bidirectional echo of 1 MB (records 1 MB ingress + 1 MB egress)
-- head -c 1048576 /dev/urandom | curl --data-binary @- http://HOST:8080/echo -o /dev/null
--
-- # See the app side totals
-- curl -s http://HOST:8080/stats | jq .
