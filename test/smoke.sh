#!/bin/bash
#
# Local container-level smoke test for the bge-reranker Cloudron package. No Cloudron box required: it
# builds the image and runs it the way Cloudron does (root entrypoint -> start.sh -> gosu cloudron),
# then asserts the auth topology and that reranking ACTUALLY runs on cloudron/base.
#
# This is the gate that catches the Intel MKL dlopen class of bug (the build links, but the first real
# inference can still fail). It performs a genuine /rerank, not a ping. Re-run it on any change to the
# Dockerfile, start.sh, or the upstream/model pins.
#
# Usage:  test/smoke.sh            (uses podman; set ENGINE=docker to override)
# Needs:  python3 (for JSON asserts), a working container engine, network for the first build only.

set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
ENGINE="${ENGINE:-podman}"
IMG="${IMG:-bge-reranker-cloudron:smoke}"
NAME="reranker-smoke-$$"
PORT="${PORT:-18097}"
DATADIR="$(mktemp -d)"
fail=0
note() { printf '  %-32s %s\n' "$1" "$2"; }

cleanup() {
  "$ENGINE" rm -f "$NAME" >/dev/null 2>&1
  # Files under $DATADIR are owned by the in-container cloudron uid (a subuid the host user cannot
  # remove directly), so clear them from inside a throwaway container as root first.
  "$ENGINE" run --rm -v "$DATADIR":/d:Z "$IMG" sh -c 'rm -rf /d/* /d/.[!.]* /d/..?*' >/dev/null 2>&1
  rm -rf "$DATADIR" 2>/dev/null || true
}
trap cleanup EXIT

echo "== build (cached if unchanged) =="
"$ENGINE" build -t "$IMG" -f Dockerfile . >/tmp/reranker-smoke-build.$$ 2>&1 || { echo "BUILD FAILED"; tail -20 /tmp/reranker-smoke-build.$$; rm -f /tmp/reranker-smoke-build.$$; exit 1; }
rm -f /tmp/reranker-smoke-build.$$; echo "  build ok"

echo "== run (Cloudron-style: root -> start.sh -> gosu cloudron) =="
# --memory matches the manifest memoryLimit (6 GiB), so the smoke exercises the real limit.
"$ENGINE" run -d --name "$NAME" --memory=6g -v "$DATADIR":/app/data:Z -p 127.0.0.1:$PORT:8080 "$IMG" >/dev/null 2>&1

# The nginx health shim must answer /health 200 during TEI warmup, before TEI binds its port and logs
# "Ready". This is the regression that restart-looped the app on the box; assert it is fixed.
hp=""
for i in $(seq 1 25); do
  [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:$PORT/health 2>/dev/null)" = 200 ] && { hp=$i; break; }
  "$ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -q "^$NAME$" || { echo "  CONTAINER EXITED EARLY"; "$ENGINE" logs "$NAME" 2>&1 | tail -25; exit 1; }
  sleep 1
done
if [ -n "$hp" ]; then
  rdy="$("$ENGINE" logs "$NAME" 2>&1 | grep -v '==>' | grep -c 'Ready' || true)"
  note "/health during warmup:" "200 at ~${hp}s (TEI 'Ready' count: ${rdy}, expect 0 = nginx serving)"
  { [ "$hp" -le 20 ] && [ "$rdy" = 0 ]; } || fail=1
else
  note "/health during warmup:" "NEVER (nginx shim broken)"; fail=1
fi

ready=0
for i in $(seq 1 120); do
  "$ENGINE" logs "$NAME" 2>&1 | grep -v '==>' | grep -q 'Ready' && { ready=1; break; }
  "$ENGINE" ps --format '{{.Names}}' 2>/dev/null | grep -q "^$NAME$" || { echo "  CONTAINER EXITED EARLY"; "$ENGINE" logs "$NAME" 2>&1 | tail -25; exit 1; }
  sleep 2
done
[ "$ready" = 1 ] && note "ready:" "yes (~$((i*2))s)" || { echo "  NEVER became ready"; "$ENGINE" logs "$NAME" 2>&1 | tail -25; exit 1; }

# Dropped privileges?
u="$("$ENGINE" exec "$NAME" sh -c 'ps -o user= -C text-embeddings-router' 2>/dev/null | head -1 | tr -d ' ')"
note "runs as:" "$u"; [ "$u" = cloudron ] || { echo "  EXPECTED cloudron user"; fail=1; }

# Read the generated key as root inside the container (.secrets is 0700 cloudron).
KEY="$("$ENGINE" exec "$NAME" cat /app/data/.secrets/keys.env 2>/dev/null | grep -oP 'RERANKER_API_KEY=\K.*')"
note "key length:" "${#KEY} (expect 64)"; [ "${#KEY}" = 64 ] || fail=1

# Key file mode 0600?
mode="$("$ENGINE" exec "$NAME" stat -c '%a' /app/data/.secrets/keys.env 2>/dev/null)"
note "key file mode:" "$mode (expect 600)"; [ "$mode" = 600 ] || fail=1

B="http://127.0.0.1:$PORT"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
RR='{"query":"what is panda?","texts":["hi","The giant panda (Ailuropoda melanoleuca), also known as the panda bear, is a bear species endemic to China."]}'

h=$(code "$B/health");                                                                       note "/health no-auth:" "$h"; [ "$h" = 200 ] || fail=1
n=$(code -X POST "$B/rerank" -H 'content-type: application/json' -d "$RR");                   note "/rerank no-auth:" "$n (expect 401)"; [ "$n" = 401 ] || fail=1
w=$(code -X POST "$B/rerank" -H 'Authorization: Bearer WRONG' -H 'content-type: application/json' -d "$RR"); note "/rerank wrong-key:" "$w (expect 401)"; [ "$w" = 401 ] || fail=1

# The real thing: a genuine rerank. The panda passage (index 1) must outrank "hi" (index 0).
RESP="$(curl -s -X POST "$B/rerank" -H "Authorization: Bearer $KEY" -H 'content-type: application/json' -d "$RR")"
echo "$RESP" | python3 -c '
import sys,json
r=json.load(sys.stdin)
d={x["index"]:x["score"] for x in r}
print("  rerank scores                    ", {k:round(v,4) for k,v in sorted(d.items())})
sys.exit(0 if (1 in d and 0 in d and d[1] > d[0]) else 1)
' || { note "/rerank ranking:" "WRONG (panda did not outrank hi) resp=$RESP"; fail=1; }
[ "$fail" = 0 ] && note "/rerank ranking:" "panda outranks hi (correct)" || true

# /info should report the served model name and be key-protected.
iname="$(curl -s "$B/info" -H "Authorization: Bearer $KEY" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("model_id","?"))' 2>/dev/null)"
note "/info model_id:" "${iname:-FAIL}"

# The bare domain serves a public landing page (not a blank page), so a browser sees what the API is.
rootcode=$(curl -s -o /dev/null -w '%{http_code}' "$B/")
roothtml=$(curl -s "$B/" | grep -ciE 'BGE Reranker|/rerank')
note "/ landing page:" "$rootcode, content-hits=$roothtml (expect 200, >0)"; { [ "$rootcode" = 200 ] && [ "$roothtml" -gt 0 ]; } || fail=1

# The key must never appear in the logs.
if "$ENGINE" logs "$NAME" 2>&1 | grep -qF "$KEY"; then note "key in logs:" "LEAKED"; fail=1; else note "key in logs:" "absent (good)"; fi

# Informational: real resident memory, to tune memoryLimit.
rss="$("$ENGINE" stats --no-stream --format '{{.MemUsage}}' "$NAME" 2>/dev/null | head -1)"
note "container mem usage:" "${rss:-n/a}"

echo
if [ "$fail" = 0 ]; then echo "SMOKE: PASS"; else echo "SMOKE: FAIL"; fi
exit "$fail"
