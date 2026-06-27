# Packaging notes: verified versus assumed

A running log of what was confirmed empirically against the running box, the binary, or the upstream
validator, versus what is still carried by assumption. Newest first. This is where the
empirical-verification discipline lives: before a fact is depended on in code or a doc, it is checked
and recorded here.

House rule: this file is public. It carries no real hostnames, emails, usernames, or internal URLs.
Box-specific evidence lives in the gitignored `STATUS.md`.

---

## 2026-06-27 — Phase 1 to 4: build and local gates

### Verified

- **Image builds and the linkage gate passes.** Multi-stage Shape A: TEI `cpu-1.9` binary + MKL +
  libiomp5 (`cp -L`) onto the base; `ldd` clean; `--version` runs. Model baked by curl from the pinned
  revision; the three LFS files pass `sha256sum -c`; config architecture check passes. Final image
  5.24 GB (cloudron/base ~2.5 GB + TEI/MKL ~0.3 GB + model 2.2 GB). The MKL runtime is NOT exercised
  by the linkage gate; the smoke test below is the real gate.
- **Smoke test PASS (the real MKL/inference gate).** Runs as `cloudron`; key is 64 hex at mode 0600;
  `/health` 200 without a key; `/rerank` returns TEI's own 401 without the key and with a wrong key;
  with the key it returns a genuine ranking (panda passage scores ~0.96 versus ~0.0003 for "hi"); the
  key is absent from the logs. So TEI auto-exposes `/rerank` for this model with only `--model-id`,
  loads the baked model offline, and the Candle CPU backend runs real inference on `cloudron/base`.
- **Read-only rootfs conformance.** With the rootfs mounted read-only and `/run`/`/tmp` as tmpfs (as
  Cloudron mounts it), the app still boots and reranks; a write to `/app/code` fails with EROFS; the
  process runs as `cloudron`; there are no CUDA libraries (CPU-only); the log shows the Candle "Bert
  model on Cpu" backend. So the app writes nothing outside `/app/data`, `/tmp`, `/run`.
- **Backend selection.** TEI first tries the ONNX Runtime backend, does not find an `onnx/model.onnx`
  in the baked model (the repo ships only safetensors), logs an ERROR, and falls back to the **Candle**
  backend. The ERROR line is benign (it is the documented fallback), not a failure.
- **TEI defaults observed (1.9.3):** `auto_truncate=true`, `max_batch_tokens=16384`,
  `max_client_batch_size=32`, model maximum 8192 tokens per request. `/info` reports `model_id` as the
  local baked path (cosmetic; `--served-model-name` does not override that field).
- **Memory: measured frontier.** Steady-state and warmup memory scale with the thread count and
  `max_batch_tokens` (table below). With the package defaults (threads capped at 4,
  `max_batch_tokens=4096`) the app idles at ~2.07 GB and warmup fits inside a 4 GiB limit. So
  `memoryLimit` is set to 4 GiB; re-confirm RSS on the box.

  | threads | max_batch_tokens | result | idle RSS |
  |---|---|---|---|
  | 32 | 16384 (default) | OOM even at 8 GiB | n/a |
  | 2 | 8192 | OOM at 4 GiB | n/a |
  | 4 | 4096 | OK in 4 GiB | 2.0 GB |
  | 2 | 4096 | OK in 3 GiB | 0.97 GB |

### Corrected (against the running container)

- **TEI's default `max_batch_tokens` (16384) OOM-kills warmup for this long-context model.** Warmup
  allocates O(sequence^2) attention scratch at the model's 8192-token context; at the default batch
  budget that is many GB and the container is OOM-killed during "Warming up model" with no error line
  (just exit 137). Fix: the package always passes `--max-batch-tokens 4096` (tunable up via
  `RERANKER_MAX_BATCH_TOKENS`).
- **Bounding only `RAYON_NUM_THREADS` is not enough; MKL/OpenMP must also be bounded.** The MKL math
  runtime (via libiomp5) sizes its thread pool to the visible host cores regardless of rayon, and each
  thread carries roughly 0.5 GB of working memory for this model, so on a box with no CPU limit it
  re-inflates memory and OOMs. Fix: the entrypoint caps the default thread count (`RERANKER_MAX_THREADS`,
  default 4) and exports `OMP_NUM_THREADS`/`MKL_NUM_THREADS` alongside `RAYON_NUM_THREADS`. The
  cgroup-CPU detection works (verified: `--cpus=4` -> threads 4, `--cpus=2` -> threads 2).
- **Dockerfile heredoc.** A shell heredoc (`<<'SHA'`) mixed with backslash line-continuations does not
  parse under buildah ("unterminated heredoc"). The sha256 manifest is fed via
  `printf '%s  %s\n' ... | sha256sum -c -` instead.

### Assumed / to verify on the box

- `proxyAuth` on `/docs` actually walls the Swagger UI with SSO while `/rerank` stays a 401 (verified
  the 401 locally; the SSO redirect can only be confirmed on the box).
- Whether 4 GiB is comfortable or can be reduced once the box's real CPU allotment (and thus thread
  count) is known.

---

## 2026-06-27 — Phase 0 orientation and reconnaissance

### Verified

- **The model is officially a Text Embeddings Inference (TEI) model.** `BAAI/bge-reranker-v2-m3`'s
  Hugging Face model card YAML frontmatter carries `tags: [..., text-embeddings-inference]` and
  `pipeline_tag: text-classification`. This confirms the architecture decision (ADR-0001): serve it
  with TEI, single-binary copy, model baked in.
- **Model architecture and revision.** Hugging Face API reports
  `architectures: ["XLMRobertaForSequenceClassification"]` (an XLM-RoBERTa cross-encoder, the reranker
  shape TEI exposes on `/rerank`). Current `main` commit revision pinned for reproducibility:
  `953dc6f6f85a1b2dbfca4c34a2796e7dde08d41e`. Language: multilingual.
- **Model licence is Apache-2.0, not MIT.** CORRECTION to the project brief, which stated MIT in two
  places. The model card frontmatter says `license: apache-2.0`, and the HF API `cardData.license`
  and tags agree. This is the canonical "the box wins, record the correction" case. It also resolves
  the packaging-licence instruction cleanly: both the model (Apache-2.0) and the TEI server
  (Apache-2.0) are Apache-2.0, so the package is licensed Apache-2.0. See ADR-0002.
- **Model files and content hashes** (for the build-time supply-chain gate). To bake: `config.json`
  (795 B, non-LFS), `model.safetensors` (2,271,071,852 B ≈ 2.27 GB, LFS
  sha256 `d9e3e081faff1eefb84019509b2f5558fd74c1a05a2c7db22f74174fcedb5286`),
  `tokenizer.json` (17,098,273 B, LFS sha256
  `69564b696052886ed0ac63fa393e928384e0f8caada38c1f4864a9bfbf379c15`),
  `sentencepiece.bpe.model` (5,069,051 B, LFS sha256
  `cfc8146abe2a0488e9e2a0c56de7952f7c11ab059eca145a0a727afce0db2865`),
  `tokenizer_config.json` (1,173 B, non-LFS), `special_tokens_map.json` (964 B, non-LFS). The three
  LFS files (the weights and the tokenizers, ~99.99% of the bytes) are verified by sha256 in the
  Dockerfile; the small JSON configs are fixed by the pinned commit revision.
- **TEI CPU image digest and version, re-verified.** `skopeo inspect
  docker://ghcr.io/huggingface/text-embeddings-inference:cpu-1.9` resolves to digest
  `sha256:ad950d30878eceb72aaf32024d26fa2b1d04a75304fa0b4776b49aa1941fea07`, label
  `org.opencontainers.image.version=cpu-1.9.3`, `Architecture amd64`, `Os linux`, created
  2026-03-23. So the upstream binary version is 1.9.3, served from tag `cpu-1.9`. The bare `:1.9`
  tag remains the CUDA image (gotcha #2); we use `cpu-1.9` pinned by digest.
- **Base image.** `cloudron/base:5.0.0@sha256:04fd70dbd8ad6149c19de39e35718e024417c3e01dc9c6637eaf4a41ec4e596c`
  (Ubuntu 24.04, glibc 2.39). Confirmed current by the installed Cloudron packaging skill and by the
  field guide.
- **A dedicated reranker app is the right topology.** The operator's existing `tei` Cloudron app is
  configured to serve an embedding model (`BAAI/bge-small-en-v1.5`, 384-dim), downloaded on first
  boot. TEI serves one model per process, so reranking needs its own app. This empirically confirms
  rejected alternative A in ADR-0001.
- **Weight size implies memory budget.** Weights are fp32 (~2.27 GB on disk, single safetensors
  file), so resident set will be roughly that plus runtime overhead. Start `memoryLimit` at 4 GiB and
  tune against measured RSS (smoke test, then the box).
- **Tooling present:** cloudron, podman (rootless 5.8.2, the build engine), skopeo, git, python3,
  poetry, node, pnpm, npm, jq, curl. Both git tokens readable (outside the repo, never tracked).
  Docker is installed but its daemon socket is not reachable (none at `/var/run/docker.sock` or the
  user runtime dir, even with the sandbox disabled); podman rootless covers all build/smoke needs.
- **TEI `/rerank` contract, verified against the v1.9.3 source and OpenAPI.** Request: `query`
  (string, required), `texts` (array of strings, required), `truncate` (bool, default false),
  `truncation_direction` (`Left`|`Right`, default `Right`), `raw_scores` (bool, default false),
  `return_text` (bool, default false). Response: a JSON array of `{index, score, text?}` (`text` only
  when `return_text=true`). Auth: set the `API_KEY` env var, clients send `Authorization: Bearer`;
  with no `API_KEY` the server answers every request (insecure default, which is why the package
  always sets it). Auto-detection: TEI exposes `/rerank` for any single-class sequence-classification
  model with no extra flag, and returns **424** if the model is not such a cross-encoder. So the
  smoke test asserts a real ranking (not 424).
- **No prior art to duplicate.** The only Cloudron reranker repo is the operator's own empty stub
  `bge-reranker-cloudron`; no third-party reranker/TEI Cloudron package exists, and there is no forum
  app-request thread for a reranker (so the Phase 8 request post is net-new). `hwdsl2/docker-embeddings`
  is the closest blueprint (its default rerank model is `bge-reranker-v2-m3`), but it downloads on
  first boot rather than baking, which this package improves on.

### Corrected

- Brief said the model licence is MIT. Actual: **Apache-2.0** (verified from the model card and the HF
  API). See ADR-0002.
- Brief's `/rerank` field list included `top_n`. Actual: **TEI has no `top_n`** on `/rerank` (absent
  from the Rust `RerankRequest` struct and `openapi.json` at v1.9.3). TEI returns a score for every
  text; clients sort and slice. Documentation and integration examples must not promise `top_n`.

### Assumed / to verify empirically later

- That TEI auto-detects this sequence-classification model and exposes `/rerank` with no extra flag
  beyond `--model-id`. To prove in the smoke test (a genuine rerank, not a ping).
- That a local `--model-id /app/code/models/...` path loads the baked weights with no network. To
  prove in the smoke test and by setting `HF_HUB_OFFLINE=1`.
- That 4 GiB is sufficient and not excessive. To measure (RSS) in the smoke test and on the box.
- That `/health` is auth-exempt and an unauthenticated `/rerank` returns TEI's own 401 (not an SSO
  302). To prove in the smoke test and on the box.

### Environment / operational

- The Cloudron box API is **not reachable through the sandboxed shell** (the box is on a private
  domain not in the sandbox allowlist); `cloudron` CLI calls succeed only with the sandbox disabled.
  General egress (ghcr.io, huggingface.co) works sandboxed. Recorded so box phases are not mistaken
  for outages.
- The container registry (GHCR) is **not yet logged in**; public pulls work without it. Login with
  the packager token is a Phase 5 (publish) step.
