# BAAI/bge-reranker-v2-m3 served by Text Embeddings Inference (TEI), packaged for Cloudron.
#
# This is a thin adaptation layer over the upstream TEI binary, specialised to a reranker model with
# the model weights baked into the image (no first-boot download). It is the sibling of the TEI
# embeddings package; the only structural differences are that the model is baked and --model-id
# points at the baked path. See AGENTS.md and docs/decisions/0001-architecture-tei-shape-a-baked-model.md.
#
# Pins (single source of truth): the upstream version is the TEI_VERSION build ARG and, authoritatively,
# the @sha256 digest on the upstream FROM line; the base is pinned by digest; the model is pinned by
# Hugging Face commit revision and the three large files are sha256-verified at build time.
#
# Like the TEI CPU build, this is amd64-only: text-embeddings-inference's CPU image bundles Intel MKL
# and has no arm64 CPU variant.

ARG TEI_VERSION=1.9

# --- Stage 1: the official upstream CPU image, used only as a source for the binary + MKL runtime ----
# Pinned by digest (re-verified 2026-06-27: tag cpu-1.9 -> this digest, label version cpu-1.9.3, amd64).
# NOTE: the bare ":1.9"/":latest" tags are CUDA images; the CPU build is the "cpu-" prefixed tag.
FROM ghcr.io/huggingface/text-embeddings-inference:cpu-1.9@sha256:ad950d30878eceb72aaf32024d26fa2b1d04a75304fa0b4776b49aa1941fea07 AS upstream

# Gather every runtime artifact into one tree, dereferencing symlinks (cp -L). The libiomp5.so in the
# upstream image is a symlink to LLVM's libomp.so.5; -L copies the real library out as a concrete file
# named libiomp5.so, which is the soname the MKL threading layer and the binary's DT_NEEDED both ask
# for. It is resolved at runtime via LD_LIBRARY_PATH (not ldconfig, which would index it under the
# wrong internal soname). See docs/decisions/0001 and field guide gotcha #3.
RUN set -eux; \
    mkdir -p /gather/lib; \
    cp -L /usr/local/bin/text-embeddings-router /gather/text-embeddings-router; \
    cp -L /usr/local/libfakeintel.so            /gather/libfakeintel.so; \
    cp -L /usr/local/lib/*.so*                  /gather/lib/; \
    cp -L /lib/x86_64-linux-gnu/libiomp5.so     /gather/lib/libiomp5.so; \
    ls -l /gather /gather/lib

# --- Stage 2: the Cloudron app image ----------------------------------------------------------------
# The final stage must be this exact base so the Cloudron file manager, web terminal, and log viewer
# work. Tag 5.0.0 -> this digest (Ubuntu 24.04, glibc 2.39). The upstream binary was built on Debian
# bookworm (glibc 2.36), which 2.39 satisfies (forward-compatible).
FROM cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c

# cloudron/base provides gosu, curl, openssl, ca-certificates, coreutils, and the binary's standard
# shared libs (libstdc++6, libssl3, libcrypto, libgcc_s, libm, libc). The only things not on the base
# are TEI's own binary and its MKL/OpenMP runtime, copied below; so no apt-get install is needed.

# 1) The binary, the LD_PRELOAD shim, and the MKL + libiomp5 runtime. Resolved at runtime via
#    LD_LIBRARY_PATH (set below), NOT via ldconfig (see the cp -L note above).
COPY --from=upstream /gather/text-embeddings-router /app/code/text-embeddings-router
COPY --from=upstream /gather/libfakeintel.so        /usr/local/libfakeintel.so
COPY --from=upstream /gather/lib/                    /usr/local/lib/

# 2) Runtime environment the binary needs (mirrors the upstream image defaults): the libfakeintel
#    preload, the MKL library search path, and the MKL instruction ceiling (still gated by the real
#    CPUID, so it is an upper bound, not a force; falls back on CPUs without AVX-512).
ENV LD_PRELOAD=/usr/local/libfakeintel.so \
    LD_LIBRARY_PATH=/usr/local/lib \
    MKL_ENABLE_INSTRUCTIONS=AVX512_E4

# 3) Linkage gate (build-time): fail the BUILD if the binary cannot resolve its DIRECT shared-library
#    dependencies on this base, and confirm it executes. The libmkl_*.so are dlopened at inference
#    time (not DT_NEEDED), so this gate does NOT exercise the MKL load path; the runtime /rerank smoke
#    test (test/smoke.sh) is the real gate.
RUN set -eux; \
    ldd /app/code/text-embeddings-router; \
    if ldd /app/code/text-embeddings-router 2>&1 | grep -qE 'not found'; then \
      echo "FATAL: unresolved shared library or glibc symbol on this base"; exit 1; \
    fi; \
    /app/code/text-embeddings-router --version

# 4) Bake the model. Download exactly the model + tokenizer files from the pinned Hugging Face commit
#    revision (no Python, no pip, no download cache to bloat the layer; curl is on the base), then
#    verify the three large LFS files by sha256. config.json/tokenizer_config.json/special_tokens_map
#    are small and fixed by the pinned revision. Files land mode 0644 in 0755 dirs (root umask 022),
#    readable by the cloudron user, so no chmod -R is needed (which would create a fat copy-up layer).
ARG MODEL_REPO=BAAI/bge-reranker-v2-m3
ARG MODEL_REVISION=953dc6f6f85a1b2dbfca4c34a2796e7dde08d41e
ENV MODEL_REPO=${MODEL_REPO} \
    MODEL_REVISION=${MODEL_REVISION} \
    MODEL_DIR=/app/code/models/bge-reranker-v2-m3
RUN set -eux; \
    mkdir -p "${MODEL_DIR}"; cd "${MODEL_DIR}"; \
    base="https://huggingface.co/${MODEL_REPO}/resolve/${MODEL_REVISION}"; \
    for f in config.json model.safetensors tokenizer.json tokenizer_config.json special_tokens_map.json sentencepiece.bpe.model; do \
      echo "==> fetching ${f}"; \
      curl -fL --retry 5 --retry-delay 2 --retry-connrefused -o "${f}" "${base}/${f}"; \
    done; \
    printf '%s  %s\n' \
      d9e3e081faff1eefb84019509b2f5558fd74c1a05a2c7db22f74174fcedb5286 model.safetensors \
      69564b696052886ed0ac63fa393e928384e0f8caada38c1f4864a9bfbf379c15 tokenizer.json \
      cfc8146abe2a0488e9e2a0c56de7952f7c11ab059eca145a0a727afce0db2865 sentencepiece.bpe.model \
      | sha256sum -c -; \
    grep -q 'XLMRobertaForSequenceClassification' config.json; \
    echo "==> model baked ($(du -sh "${MODEL_DIR}" | cut -f1)):"; ls -l "${MODEL_DIR}"

# 5) The entrypoint and the licence. start.sh is COPYed last (it changes most often) so editing it does
#    not invalidate the large model layer above.
COPY start.sh   /app/code/start.sh
COPY nginx.conf /app/code/nginx.conf
COPY www/       /app/code/www/
COPY LICENSE    /app/code/LICENSE
# nginx ships in cloudron/base; it fronts TEI to answer /health during warmup. Fail the build if it
# is ever absent from the base, and validate the proxy config syntax.
RUN chmod 0755 /app/code/text-embeddings-router /app/code/start.sh; \
    command -v nginx >/dev/null || { echo "FATAL: nginx not on base"; exit 1; }; \
    mkdir -p /run/nginx/body /run/nginx/proxy /run/nginx/fastcgi /run/nginx/uwsgi /run/nginx/scgi; \
    nginx -t -c /app/code/nginx.conf

# 6) Record the pinned upstream version, disable telemetry defensively, and label the image.
ARG TEI_VERSION
ENV TEI_VERSION=${TEI_VERSION} \
    HF_HUB_DISABLE_TELEMETRY=1 \
    DO_NOT_TRACK=1

LABEL org.opencontainers.image.title="bge-reranker-cloudron" \
      org.opencontainers.image.description="BAAI/bge-reranker-v2-m3 reranking API on HuggingFace TEI, packaged for Cloudron (model baked in)" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/OrcVole/bge-reranker-cloudron"

WORKDIR /app/code

# start.sh runs as root, prepares /app/data, then drops to the cloudron user via gosu.
CMD [ "/app/code/start.sh" ]
