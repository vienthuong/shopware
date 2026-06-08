#!/usr/bin/env bash
# Real `http` executor for the reproduce pipeline.
#
# Reads the repro plan (analysis.json), issues the request it describes against a
# running Shopware (APP_URL), evaluates the assertion, and writes result.json per
# .claude/skills/reproduce/references/SCHEMA.md. No browser, no asset build — the
# cheapest faithful surface for store-api / admin-api bugs. HAR-style evidence.
#
# Env:
#   ANALYSIS      path to analysis.json            (default: analysis.json)
#   OUT           path to write result.json        (default: result.json)
#   APP_URL       base URL of the running shop, e.g. http://localhost:8000  (required)
#   SW_ACCESS_KEY store-api sales-channel access key (optional; store-api layer)
#   TARGET        reported | trunk                 (required)
set -euo pipefail

ANALYSIS=${ANALYSIS:-analysis.json}
OUT=${OUT:-result.json}
: "${APP_URL:?APP_URL is required}"
: "${TARGET:?TARGET is required}"
ACCESS_KEY=${SW_ACCESS_KEY:-}

VERSION=$(jq -r '.version // "unknown"' "$ANALYSIS")
METHOD=$(jq -r '.request.method // "GET"' "$ANALYSIS")
REQ_PATH=$(jq -r '.request.path // .assertion.locator' "$ANALYSIS")
BODY=$(jq -r '.request.body // ""' "$ANALYSIS")
KIND=$(jq -r '.assertion.kind' "$ANALYSIS")
EXPECT=$(jq -r '.assertion.expect | tostring' "$ANALYSIS")
FIELD=$(jq -r '.assertion.field // ""' "$ANALYSIS")

BASE=${APP_URL%/}
URL="$BASE$REQ_PATH"
HEAD=$(mktemp); BODYFILE=$(mktemp)
trap 'rm -f "$HEAD" "$BODYFILE"' EXIT

# Build the request. Header order: access key, then plan headers.
CURL=(curl -sS --max-time 30 -o "$BODYFILE" -D "$HEAD" -w '%{http_code}' -X "$METHOD" "$URL")
DISPLAY_H=""
if [ -n "$ACCESS_KEY" ]; then
  CURL+=(-H "sw-access-key: $ACCESS_KEY")
  DISPLAY_H+=" -H \"sw-access-key: [REDACTED_KEY]\""
fi
while IFS= read -r h; do
  [ -n "$h" ] || continue
  CURL+=(-H "$h")
  DISPLAY_H+=" -H \"$h\""
done < <(jq -r '.request.headers // {} | to_entries[] | "\(.key): \(.value)"' "$ANALYSIS")
if [ -n "$BODY" ]; then
  CURL+=(--data "$BODY")
  DISPLAY_BODY=" --data '$BODY'"
else
  DISPLAY_BODY=""
fi
# Verbatim, reproducible, redacted: literal $APP_URL (no host leak), redacted key.
SCRIPT="curl -sS -X $METHOD \"\$APP_URL$REQ_PATH\"$DISPLAY_H$DISPLAY_BODY"

# One bounded retry on transport failure, then `blocked` (dead env — don't grind).
CODE=""; transport_ok=1
if ! CODE=$("${CURL[@]}" 2>/dev/null); then
  sleep 3
  CODE=$("${CURL[@]}" 2>/dev/null) || transport_ok=0
fi

if [ "$transport_ok" = 0 ]; then
  STATUS="blocked"; MATCHED="null"; ACTUAL="null"; REASON="\"endpoint unreachable after one retry: $METHOD $REQ_PATH\""
  REPORTER="transport failure (env not READY)"
else
  REASON="null"
  case "$KIND" in
    http_status)
      ACTUAL_RAW="$CODE"
      REPORTER="HTTP $CODE (expected $EXPECT)" ;;
    response_field)
      ACTUAL_RAW=$(jq -r "$FIELD" "$BODYFILE" 2>/dev/null || echo "<unparseable>")
      REPORTER="$FIELD = '$ACTUAL_RAW' (expected '$EXPECT')" ;;
    *)
      ACTUAL_RAW="$CODE"
      REPORTER="HTTP $CODE (unknown assertion kind '$KIND')" ;;
  esac
  # assertion.expect is the HEALTHY value (derived from the fix PR's regression test).
  # symptom observed (assertion fails) => reproduced; healthy (assertion holds) => not_reproduced.
  if [ "$ACTUAL_RAW" = "$EXPECT" ]; then
    MATCHED="true"; STATUS="not_reproduced"
  else
    MATCHED="false"; STATUS="reproduced"
  fi
  ACTUAL="\"$ACTUAL_RAW\""
fi

jq -n \
  --argjson issue "$(jq -r '.issue' "$ANALYSIS")" \
  --arg target "$TARGET" --arg version "$VERSION" --arg status "$STATUS" \
  --arg expect "$EXPECT" --argjson actual "$ACTUAL" --argjson matched "$MATCHED" \
  --arg script "$SCRIPT" --arg reporter "$REPORTER" \
  --arg method "$METHOD" --arg path "$REQ_PATH" --argjson code "${CODE:-0}" \
  --argjson reason "$REASON" '{
    schema_version: "1",
    issue: $issue,
    target: $target,
    version: $version,
    executor: "http",
    status: $status,
    assertion: { expect: $expect, actual: ($actual | if . == null then null else tostring end), matched: $matched },
    duration_s: 0,
    evidence: {
      script: $script,
      script_lang: "sh",
      reporter_output: $reporter,
      http: [{ method: $method, path: $path, status: $code }],
      artifacts: [],
      truncated: false
    },
    blocked_reason: $reason
  }' > "$OUT"

echo "status=$STATUS  ($REPORTER)"
