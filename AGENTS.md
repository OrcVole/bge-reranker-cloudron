# AGENTS.md

This file is the working contract for any AI agent or human who edits this repository. Read it fully
before changing anything. It encodes decisions that are already settled, so they are not relitigated
each session and conformance does not regress.

If you are an AI agent: treat the "Golden rules" as hard constraints. When a request conflicts with
them, stop and surface the conflict rather than working around it.

This repository packages **`BAAI/bge-reranker-v2-m3`** — an XLM-RoBERTa cross-encoder reranker,
Apache-2.0, multilingual — served by **Hugging Face Text Embeddings Inference (TEI)** as a
**Cloudron-conformant application**. The model weights are baked into the image; the server is the
upstream TEI binary, unpatched. The goals, in order: (1) it runs cleanly and securely on Cloudron,
(2) the repository is public so others can use it, (3) it is written to a standard where the Cloudron
team could adopt it as an official application.

It is the reranking half of a two-stage retrieve-then-rerank stack; the embeddings half is served by
a separate TEI app. The two are packaged separately because TEI serves one model per process.

---

## 1. Golden rules (non-negotiable)

1. **Conformance first.** A Cloudron package is a thin adaptation layer. Adapt the runtime
   environment; never patch the application. A change that writes outside the allowed paths, runs as
   root at runtime, or skips the health check is wrong.
2. **Pin the upstream version in exactly one place** — the `TEI_VERSION` build ARG. The manifest's
   `upstreamVersion` mirrors it as read-only metadata. Pin the base image and the upstream TEI image
   by `@sha256` digest. Pin the model by Hugging Face commit revision. Never a floating tag
   (`latest`, `stable`, bare `:1.9` — the bare tag is the CUDA image; use `cpu-`).
3. **Do not break the auth topology.** `proxyAuth` walls human surfaces only, path-scoped to `/docs`.
   The programmatic `/rerank` API stays open at the network layer and is protected by the app's own
   Bearer key. Never put the SSO wall in front of the API (it 302-redirects clients and breaks every
   integration). Never set `supportsBearerAuth` on the `/docs` wall.
4. **All persisted state lives under `/app/data`** (the only backed-up, writable, persistent path).
   `/run` and `/tmp` are ephemeral; everything else is read-only at runtime. The baked model lives
   under `/app/code` (read-only, reproducible from the image, not backed up).
5. **Bake heavy assets; never download on first boot.** The model weights go into the image at build
   time. A first-boot download races Cloudron's health grace window.
6. **Fail loud.** `start.sh` uses `set -euo pipefail`, prefixes every package line with `==>`, and
   echoes resolved facts (port, threads, key presence) but never secrets.
7. **Idempotent secret seeding.** Generate the API key once on first run; never reseed on
   restart/update. Re-assert its ownership and `0600`/`0700` mode every boot (a restore drifts them).
8. **Code and docs ship together.** Every non-obvious decision is an ADR; every verified-versus-assumed
   fact goes in `docs/PACKAGING-NOTES.md`, newest first.
9. **Anonymity is a release gate.** No real hostname, email, username, internal URL, or token in any
   tracked file. Box-specific docs (`STATUS.md`, `RECON.md`) are gitignored. `test/secret-scan.sh`
   runs before every push.
10. **`CMD`, never `ENTRYPOINT`** (`ENTRYPOINT` breaks `cloudron debug`). `.dockerignore`, not just
    `.gitignore` (the build context ignores `.gitignore`).
11. **House style for prose:** Markdown and open formats only. No em dashes. Full words rather than
    contractions. Comments explain why, not what, especially Cloudron-specific workarounds.
12. **Verify, do not assume.** When an upstream flag, image layout, env var, or Cloudron capability
    might have changed, confirm it empirically against the running box or binary and record what was
    verified versus assumed in `docs/PACKAGING-NOTES.md`. The box wins over any document, including
    this one.

---

## 2. What this repository is and is not

- It **is** a thin, reproducible packaging layer: a Dockerfile, an entrypoint, a manifest, an icon,
  and docs.
- It **is not** a fork of TEI or of the model. Neither is patched. The package consumes the official
  TEI release image and the official model weights and adapts only the runtime environment to
  Cloudron.
- Upstream owns the inference behaviour. This package owns the packaging, the security defaults, the
  topology, and the upgrade path.

---

## 3. Pinned versions and the single source of truth

| Component | Pin |
|---|---|
| TEI (upstream, CPU) | `cpu-1.9`, `ghcr.io/huggingface/text-embeddings-inference:cpu-1.9@sha256:ad950d30878eceb72aaf32024d26fa2b1d04a75304fa0b4776b49aa1941fea07` (binary reports 1.9.3) |
| Cloudron base | `cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c` (Ubuntu 24.04, glibc 2.39) |
| Model | `BAAI/bge-reranker-v2-m3` @ revision `953dc6f6f85a1b2dbfca4c34a2796e7dde08d41e`, baked into `/app/code/models/bge-reranker-v2-m3`, three LFS files sha256-verified at build |

The upstream CPU build is **amd64 only** (it bundles Intel MKL; there is no arm64 CPU image), so the
package targets amd64 hosts.

The multi-stage build copies, out of the upstream image: the `text-embeddings-router` binary, the
`libfakeintel.so` `LD_PRELOAD` shim, the `/usr/local/lib/libmkl_*.so` math runtime, and `libiomp5.so`.
The non-obvious part: `libiomp5.so` is a symlink whose real soname is `libomp.so.5`, so it is resolved
at runtime through `LD_LIBRARY_PATH=/usr/local/lib` (not `ldconfig`, which would index it under the
wrong name); `cp -L` dereferences it into a concrete file. The build-time linkage gate does NOT
exercise the MKL libraries (they are `dlopen`ed at first inference), so the runtime `/rerank` smoke
test is the real gate.

---

## 4. Cloudron conformance rules

- **Base image:** the final build stage is `cloudron/base`, pinned by digest.
- **Read-only root filesystem.** Only `/tmp`, `/run`, and `/app/data` are writable. The router reads
  the baked model from `/app/code` (read-only) and writes only to `HF_HOME`/cache under `/app/data`.
- **Code under `/app/code`** (read-only at runtime). **State under `/app/data`** (the `localstorage`
  addon, the only backed-up location). Chown `/app/data` in `start.sh` before dropping privileges.
- **Run as the `cloudron` user** via `gosu cloudron:cloudron`. The `cloudron` user cannot bind
  privileged ports, so the listener is on 8080.
- **Health check:** `healthCheckPath` is `/health`, returns 200 as soon as the listener binds, exempt
  from the API key (verify empirically). Liveness, not readiness.
- **Instant usability:** no setup screen. Because the model is baked, the app is ready in seconds; the
  generated key is surfaced through `postInstallMessage` and the checklist.

---

## 5. Architecture and topology (the crux)

TEI exposes its endpoints on one HTTP port (8080):

- **Reranking API** (`/rerank`, `/info`, `/metrics`): protected by the API key
  (`Authorization: Bearer`).
- **Health** (`/health`): open, no key, so Cloudron can monitor the app.
- **Interactive Swagger docs** (`/docs`): the only browsable surface; behind Cloudron login.

The package scopes `proxyAuth` to `/docs` only, so Cloudron single sign-on guards the docs UI while
the reranking API stays open at the network level and is protected by the key. An unauthenticated API
request returns TEI's own 401, not a login redirect. **Never** widen proxyAuth to cover the API, and
never set `supportsBearerAuth` on the `/docs` wall (it would open the wall to any dummy bearer).

The key is generated once on first run, stored at `/app/data/.secrets/keys.env` (`0600` in a `0700`
dir), injected through the `API_KEY` environment variable so it never appears in the process table,
and never echoed to logs.

---

## 6. Configuration model

TEI is configured by command-line flags and their environment equivalents; there is no operator config
file to seed. `start.sh` owns the configuration:

- **Package-forced** (operator cannot override): the listen host (`--hostname 0.0.0.0`, because the
  container's `HOSTNAME` is the container id) and port, the API key, the baked `--model-id`, the
  caches under `/app/data`, and offline mode (`HF_HUB_OFFLINE=1`, telemetry disabled).
- **Operator-tunable** through the app Environment: the optional `RERANKER_REVISION`, `RERANKER_DTYPE`,
  `RERANKER_AUTO_TRUNCATE`, `RERANKER_SERVED_MODEL_NAME`, `RERANKER_NUM_THREADS`, `RERANKER_HTTP_PORT`.
  The thread pool defaults to the cgroup CPU allotment. (The model itself is fixed: it is baked. An
  operator who wants a different model uses the embeddings TEI package or a different install.)

First-run seeding (only the API key) is idempotent: written only when absent, so an update or restart
never clobbers it.

---

## 7. Definition of done (pre-commit checklist)

- [ ] No write paths outside `/tmp`, `/run`, `/app/data` (verified on a real or local run).
- [ ] Runs as `cloudron`, not root.
- [ ] Upstream version pinned in one canonical place; base and TEI images pinned by digest; the model
      pinned by revision and sha256; the `cpu-` tag (never the CUDA tag).
- [ ] Topology unchanged, or the change is recorded in an ADR and README and re-verified.
- [ ] `start.sh` uses `set -euo pipefail` and prints `==>` markers; first-run seeding is idempotent;
      key mode/owner re-asserted every boot.
- [ ] Health check returns 2xx and is unauthenticated.
- [ ] `test/smoke.sh` passes (genuine `/rerank`, key not in logs); the relevant box gate passes.
- [ ] README, CHANGELOG, PACKAGING-NOTES, THINGS-LEARNED updated as relevant.
- [ ] `test/secret-scan.sh` clean: no secret, personal host, email, or token in any tracked file.
- [ ] Prose follows house style: no em dashes, full words, open formats.
