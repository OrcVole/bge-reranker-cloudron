[1.0.1]

- Upstream text-embeddings-inference 1.9.3 to 1.9.4. The amd64 CPU build is unchanged.
- Base image cloudron/base 5.0.0 to 5.1.0: the Ubuntu 24.04.4 point release, with its OS security
  updates. Same Ubuntu 24.04 release and glibc 2.39.

[1.0.0]

- First release.
- Serves BAAI/bge-reranker-v2-m3 (Apache-2.0, multilingual XLM-RoBERTa cross-encoder) on Hugging Face
  Text Embeddings Inference 1.9.3 (CPU build), packaged for Cloudron.
- Model weights are baked into the image and pinned by Hugging Face commit revision, with the large
  files verified by sha256 at build time. The app is ready within seconds of install, fully offline.
- Reranking API on POST /rerank, protected by an auto-generated Bearer API key. The /health path is
  open; the Swagger docs at /docs are behind Cloudron single sign-on.
- TEI is fronted by a small nginx reverse proxy that answers /health immediately, so the app stays
  healthy during the model warmup (TEI binds its port only after warmup) instead of restart-looping.
- Corrected 2026-09-25: the entry above is wrong about restart-looping. Cloudron's health check never
  restarts a container; it only reports status. The first-install loop was most likely an out-of-memory
  kill during warmup (exit 137), fixed by the memory limit raise in the same release. The health proxy
  stays: it keeps the dashboard showing the app healthy during warmup and is harmless.
- memoryLimit is 6 GiB to cover the warmup memory peak.
- Read-only root filesystem, runs as the unprivileged cloudron user, all state under /app/data.
