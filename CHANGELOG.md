[1.0.0]
* First release.
* Serves BAAI/bge-reranker-v2-m3 (Apache-2.0, multilingual XLM-RoBERTa cross-encoder) on Hugging Face
  Text Embeddings Inference 1.9.3 (CPU build), packaged for Cloudron.
* Model weights are baked into the image and pinned by Hugging Face commit revision, with the large
  files verified by sha256 at build time. The app is ready within seconds of install, fully offline.
* Reranking API on POST /rerank, protected by an auto-generated Bearer API key. The /health path is
  open; the Swagger docs at /docs are behind Cloudron single sign-on.
* Read-only root filesystem, runs as the unprivileged cloudron user, all state under /app/data.
