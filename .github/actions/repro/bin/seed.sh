#!/usr/bin/env bash
# Seed exactly the entities a repro needs, via the admin sync API. NO demodata.
#
# Reads the plan's sync payload (entities the Analyze agent derived), resolves the
# install-specific placeholders ({{SC}}/{{NAV_CAT}}/{{TAX}}/{{CURRENCY}}) against the
# running shop, and POSTs /api/_action/sync. Idempotent upsert.
#
# Env:
#   APP_URL     base URL of the running shop          (required)
#   PAYLOAD     path to the sync payload JSON          (default: fixtures.json)
#   ADMIN_USER  admin username (default-install: admin)
#   ADMIN_PASS  admin password (default-install: shopware)
set -euo pipefail

: "${APP_URL:?APP_URL is required}"
PAYLOAD="${PAYLOAD:-fixtures.json}"
BASE=${APP_URL%/}
USER="${ADMIN_USER:-admin}"
PASS="${ADMIN_PASS:-shopware}"

# A plan with no fixtures is valid (e.g. demodata:false + the bug needs no seed data).
if [ ! -f "$PAYLOAD" ]; then
  echo "no fixtures payload ($PAYLOAD) — nothing to seed"
  exit 0
fi

# 1. Admin token via the first-party password grant (works on a default install).
TOKEN=$(curl -sS --max-time 30 -X POST "$BASE/api/oauth/token" \
  -H 'Content-Type: application/json' \
  -d "{\"grant_type\":\"password\",\"client_id\":\"administration\",\"username\":\"$USER\",\"password\":\"$PASS\",\"scopes\":\"write\"}" \
  | jq -r '.access_token // empty')
[ -n "$TOKEN" ] || { echo "::error::admin token request failed"; exit 1; }
AUTH=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')

# 2. Resolve install-specific ids referenced by the payload as placeholders.
search () { curl -sS --max-time 30 -X POST "$BASE/api/search/$1" "${AUTH[@]}" -d "$2"; }
SC_JSON=$(search sales-channel '{"limit":1,"filter":[{"type":"equals","field":"active","value":true}]}')
SC=$(echo "$SC_JSON"  | jq -r '.data[0].id // empty')
NAV=$(echo "$SC_JSON" | jq -r '.data[0].navigationCategoryId // empty')
TAX=$(search tax '{"limit":1}'      | jq -r '.data[0].id // empty')
CUR=$(search currency '{"limit":1,"filter":[{"type":"equals","field":"isoCode","value":"EUR"}]}' | jq -r '.data[0].id // empty')

OUT=$(mktemp)
sed -e "s/{{SC}}/$SC/g" -e "s/{{NAV_CAT}}/$NAV/g" -e "s/{{TAX}}/$TAX/g" -e "s/{{CURRENCY}}/$CUR/g" "$PAYLOAD" > "$OUT"

# Fail loud if any placeholder is still unresolved (would seed broken entities).
if grep -q '{{' "$OUT"; then
  echo "::error::unresolved placeholder(s) in sync payload:"; grep -o '{{[^}]*}}' "$OUT" | sort -u
  exit 1
fi

# 3. Upsert the entities.
RESP=$(mktemp)
CODE=$(curl -sS --max-time 60 -o "$RESP" -w '%{http_code}' -X POST "$BASE/api/_action/sync" "${AUTH[@]}" --data @"$OUT")
if [ "$CODE" != "200" ] && [ "$CODE" != "204" ]; then
  echo "::error::sync failed (HTTP $CODE)"; cat "$RESP"; exit 1
fi
echo "seeded OK (sync HTTP $CODE; SC=$SC nav=$NAV tax=$TAX cur=$CUR)"
