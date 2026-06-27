#!/bin/bash
#
# Cloudron entrypoint for BAAI/bge-reranker-v2-m3 served by Text Embeddings Inference (TEI).
#
# Runs as root, prepares /app/data, generates and persists a single API key on first run, exports the
# package-forced settings, then drops to the cloudron user and execs the router against the BAKED
# model (no download). Every package-emitted line is prefixed with "==>" so logs are greppable.

set -euo pipefail

CODE=/app/code
DATA=/app/data
BIN="${CODE}/text-embeddings-router"

# The model is baked into the image (read-only, reproducible, not under /app/data). MODEL_DIR is set
# in the Dockerfile; default it here too so the script is self-contained.
MODEL_DIR="${MODEL_DIR:-/app/code/models/bge-reranker-v2-m3}"

SECRETS_DIR="${DATA}/.secrets"
KEYS_ENV="${SECRETS_DIR}/keys.env"
HF_DIR="${DATA}/hf"               # HF_HOME: any HF state the libs touch (writable, backed up)
HUB_CACHE="${DATA}/hub"           # HUGGINGFACE_HUB_CACHE (unused at runtime: offline + local model)
CACHE_DIR="${DATA}/cache"         # XDG cache
VERSION="${TEI_VERSION:-unknown}"

# The public port (the manifest httpPort) is served by nginx, which answers /health immediately and
# proxies everything else to TEI on an internal port. These are fixed because nginx.conf references
# them; they are not operator-tunable.
PUBLIC_PORT=8080
TEI_PORT=8081
# /info reports this as the model name; default to the real repo id rather than the local path.
SERVED_NAME="${RERANKER_SERVED_MODEL_NAME:-BAAI/bge-reranker-v2-m3}"

echo "==> [start] bge-reranker-v2-m3 on text-embeddings-inference ${VERSION} booting"

# 1. Ownership and layout first. Backups/restores can reset ownership, so fix it before anything else.
#    All persistent state (HF home, caches, the key) lives under /app/data so it is backed up. The
#    model is NOT here: it is baked under /app/code (read-only).
echo "==> [start] preparing ${DATA} (hf home, caches, secrets)"
mkdir -p "${HF_DIR}" "${HUB_CACHE}" "${CACHE_DIR}" "${SECRETS_DIR}"
chown -R cloudron:cloudron "${DATA}"
chmod 0700 "${SECRETS_DIR}"

# nginx scratch under /run (a tmpfs, writable); the root filesystem is read-only at runtime.
NGINX_RUN=/run/nginx
mkdir -p "${NGINX_RUN}/body" "${NGINX_RUN}/proxy" "${NGINX_RUN}/fastcgi" "${NGINX_RUN}/uwsgi" "${NGINX_RUN}/scgi"
chown -R cloudron:cloudron "${NGINX_RUN}"

# 2. First run only: generate the API key. One key, no read-only tier. Never clobber an existing key;
#    it is the user's credential and integrators may have it configured (idempotent seeding).
if [[ ! -f "${KEYS_ENV}" ]]; then
  echo "==> [start] first run: generating API key"
  GEN_KEY="$(openssl rand -hex 32)"
  ( umask 077; cat > "${KEYS_ENV}" <<EOF
# bge-reranker-v2-m3 API key, generated on first run. Treat as a secret.
# RERANKER_API_KEY: send as "Authorization: Bearer <key>" to /rerank, /info, /metrics.
# The /health path is open (no key) and /docs is behind Cloudron login.
RERANKER_API_KEY=${GEN_KEY}
EOF
  )
  unset GEN_KEY
  echo "==> [start] API key stored at ${KEYS_ENV}"
else
  echo "==> [start] existing API key found"
fi
# Re-assert ownership and mode on EVERY boot: a restore returns keys.env as 0644/root (field guide
# gotcha #12). The 0700 parent still blocks traversal, but assert the intended mode regardless.
chown cloudron:cloudron "${KEYS_ENV}"
chmod 0600 "${KEYS_ENV}"

# 3. Load the generated key and export the package-forced settings. The key is exported as API_KEY
#    (the env var TEI reads) rather than a --api-key flag, so it never appears in the process table.
# shellcheck disable=SC1090,SC1091
set -a; . "${KEYS_ENV}"; set +a
export API_KEY="${RERANKER_API_KEY}"

# Caches under /app/data; offline + telemetry-off so the baked model never triggers a network call.
export HF_HOME="${HF_DIR}"
export HUGGINGFACE_HUB_CACHE="${HUB_CACHE}"
export XDG_CACHE_HOME="${CACHE_DIR}"
export HF_HUB_OFFLINE=1
export TRANSFORMERS_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export DO_NOT_TRACK=1

# 4. Concurrency, sized to the cgroup CPU allotment Cloudron grants this app (not the host nproc).
#    RAYON_NUM_THREADS drives the inference thread pool; tokenization workers parse payloads.
CPUS="$(nproc 2>/dev/null || echo 2)"
if [[ -r /sys/fs/cgroup/cpu.max ]]; then
  read -r CQ CP < /sys/fs/cgroup/cpu.max || true
  if [[ "${CQ:-max}" != "max" && "${CP:-0}" -gt 0 ]]; then
    C=$(( CQ / CP )); (( C >= 1 )) && CPUS=$C
  fi
fi
# Cap the default thread count. Each inference/tokenization thread carries large MKL and tokenizer
# working memory (empirically ~0.5 GB per thread for this model), so on a box that imposes no CPU
# limit, scaling to every host core would blow memoryLimit during warmup and OOM-kill first boot.
# Default to at most RERANKER_MAX_THREADS (4); operators with more RAM can raise RERANKER_NUM_THREADS.
CAP="${RERANKER_MAX_THREADS:-4}"
(( CPUS > CAP )) && CPUS=$CAP
THREADS="${RERANKER_NUM_THREADS:-${CPUS}}"
(( THREADS < 1 )) && THREADS=1
export RAYON_NUM_THREADS="${THREADS}"
export TOKENIZATION_WORKERS="${THREADS}"
# Also bound the MKL / OpenMP (libiomp5) thread pool. It otherwise sizes to the visible host cores
# regardless of RAYON_NUM_THREADS, and on a box that imposes no CPU limit that would multiply the
# per-thread MKL working memory and OOM the warmup. This is what makes the thread cap above effective.
export OMP_NUM_THREADS="${THREADS}"
export MKL_NUM_THREADS="${THREADS}"

# 5. Informational: log the cgroup memory limit (model RAM scales with model size; this is ~568M
#    params, fp32, so resident set is roughly 2.3 GB plus overhead).
if [[ -r /sys/fs/cgroup/memory.max ]]; then
  echo "==> [start] cgroup memory.max=$(cat /sys/fs/cgroup/memory.max) bytes"
fi

# 6. Fail loud if the baked model is missing (should be impossible: the build verifies it).
if [[ ! -f "${MODEL_DIR}/model.safetensors" || ! -f "${MODEL_DIR}/config.json" ]]; then
  echo "==> [start] FATAL: baked model not found at ${MODEL_DIR}"; exit 1
fi

# 7. Assemble the argument vector. --hostname/--port are on the command line because the container's
#    HOSTNAME env is the container id (would bind the wrong interface) and the port must be
#    deterministic for the Cloudron proxy. --model-id is the BAKED local path, so TEI loads offline.
# --max-batch-tokens is ALWAYS set with a frugal default. TEI's upstream default (16384) warms up by
# allocating O(sequence^2) attention scratch at this model's 8192-token context, which needs many GB
# and OOM-kills the warmup. 4096 keeps warmup and per-request memory bounded; it also caps the
# effective single-input length (auto-truncate trims longer query+passage pairs). Operators who need
# longer context can raise RERANKER_MAX_BATCH_TOKENS together with memoryLimit.
MAX_BATCH_TOKENS="${RERANKER_MAX_BATCH_TOKENS:-4096}"
ARGS=( --model-id "${MODEL_DIR}" --hostname 127.0.0.1 --port "${TEI_PORT}" \
       --served-model-name "${SERVED_NAME}" --max-batch-tokens "${MAX_BATCH_TOKENS}" )
[[ -n "${RERANKER_DTYPE:-}" ]]         && ARGS+=( --dtype "${RERANKER_DTYPE}" )
[[ -n "${RERANKER_AUTO_TRUNCATE:-}" ]] && ARGS+=( --auto-truncate )

# 8. Report resolved runtime facts (never the key) and hand off.
echo "==> [start] model    : ${MODEL_DIR} (baked, offline) as '${SERVED_NAME}'"
echo "==> [start] api      : POST /rerank {\"query\":..., \"texts\":[...]} with Authorization: Bearer <key>"
echo "==> [start] http     : nginx 0.0.0.0:${PUBLIC_PORT} -> TEI 127.0.0.1:${TEI_PORT} (/health open from t=0; /docs behind login)"
echo "==> [start] hf_home  : ${HF_DIR}"
echo "==> [start] threads  : ${THREADS} (rayon + tokenization; cap ${CAP})"
echo "==> [start] batch    : max-batch-tokens ${MAX_BATCH_TOKENS}"
echo "==> [start] api key  : $( [[ -s "${KEYS_ENV}" ]] && echo 'present' || echo 'MISSING' )"

# Start the immediate-health reverse proxy in the background. It answers /health 200 right away so
# Cloudron sees the app healthy during TEI's ~45s warmup (TEI binds its port only after warmup, which
# would otherwise restart-loop the container). Then exec TEI as the main process (PID 1) so signals
# reach it and its exit stops the container; nginx is a child and dies with it.
echo "==> [start] starting nginx health proxy on :${PUBLIC_PORT}"
gosu cloudron:cloudron nginx -c /app/code/nginx.conf &

echo "==> [start] exec text-embeddings-router ${VERSION} (warming up; /rerank available after warmup)"
exec gosu cloudron:cloudron "${BIN}" "${ARGS[@]}"
