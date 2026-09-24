#!/usr/bin/env bash
# Token al, 4 senaryoyu kostur, sonuclari tarihli dizine yaz (F15)
set -euo pipefail
cd "$(dirname "$0")/../.."
for bin in wrk jq curl; do command -v "$bin" >/dev/null || { echo "HATA: $bin kurulu degil" >&2; exit 1; }; done
BASE=${BASE:-http://localhost:28080}
OUT=api/bench/results/$(date -u +%Y%m%dT%H%M%SZ); mkdir -p "$OUT"
echo "Bench base: $BASE out: $OUT"
TOKEN=$(curl -s -X POST "$BASE/api/v1/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"editor@pgeditor.local","password":"Editor123!"}' | jq -r '.data.access_token // empty')
[ -n "$TOKEN" ] || { echo "HATA: token alinamadi" >&2; exit 1; }
export TOKEN
# connection id icin listeden al
CONN_ID=$(curl -s "$BASE/api/v1/connections" -H "Authorization: Bearer $TOKEN" | jq -r '.data[0].id // empty')
export CONN_ID
echo "CONN_ID=$CONN_ID"
wrk -t4 -c50  -d30s --latency -s api/bench/login.lua       "$BASE" | tee "$OUT/login.txt"
wrk -t4 -c100 -d30s --latency -s api/bench/connections_list.lua  "$BASE" | tee "$OUT/connections_list.txt"
wrk -t4 -c64 -d30s --latency -s api/bench/query_execute.lua "$BASE" | tee "$OUT/query_execute.txt"
wrk -t4 -c64 -d30s --latency -s api/bench/table_browser.lua "$BASE" | tee "$OUT/table_browser.txt"
# F30 hedef: /categories cache hit p95 <10 ms, /objects?category= p95 <80 ms
wrk -t4 -c32 -d15s --latency -s api/bench/schema_categories.lua "$BASE" | tee "$OUT/schema_categories.txt"
wrk -t2 -c50  -d15s --latency "$BASE/api/v1/health"                | tee "$OUT/health.txt"
# Hata orani %0 olmali: 2xx disi status ve socket hatasi varsa basarisiz
if grep -E "^status [^2][0-9]{2}:|Non-2xx|Socket errors" "$OUT"/*.txt; then
  echo "HATA: 2xx disi yanit veya socket hatasi var" >&2; exit 1
fi
echo "Sonuclar $OUT altinda"
