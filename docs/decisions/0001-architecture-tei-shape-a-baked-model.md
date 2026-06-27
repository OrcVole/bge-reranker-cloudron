# ADR-0001: Serve bge-reranker-v2-m3 with TEI (single-binary copy), model baked in

- Status: accepted
- Date: 2026-06-27

## Context

The package must serve `BAAI/bge-reranker-v2-m3` as a private, self-hosted HTTP reranking API on
Cloudron. The model is an XLM-RoBERTa sequence-classification cross-encoder (~568M parameters,
multilingual, Apache-2.0). It must protect the API with a generated key, keep any human surface behind
Cloudron SSO, ship the weights inside the image (no first-boot download), and interoperate with the
operator's existing AI stack.

## Decision

Serve the model with **Hugging Face Text Embeddings Inference (TEI)**, using the field guide's
**Shape A** (multi-stage Dockerfile: copy the `text-embeddings-router` binary and its Intel MKL
runtime out of the pinned upstream CPU image onto `cloudron/base`), with the **model weights baked
into the image** at build time and pinned by Hugging Face commit revision.

The package is a thin adaptation layer over the existing, proven TEI-on-Cloudron package: same binary,
same MKL/libiomp handling, same auth topology and port move. The deltas are exactly three:

1. Bake the model into `/app/code/models/bge-reranker-v2-m3` at build time instead of downloading it
   on first boot.
2. Point `--model-id` at that baked path (TEI loads it from disk, offline).
3. Rewrite the runtime smoke test's data-plane assertion from `/embed` to a genuine `/rerank`.

## Why this is right (empirically verified)

- **The model is officially a TEI model.** Its Hugging Face card is tagged `text-embeddings-inference`
  with `pipeline_tag: text-classification` and an `XLMRobertaForSequenceClassification` architecture.
  TEI auto-detects this shape and exposes it on `POST /rerank`. This is the canonical, production-grade,
  Rust, CPU-capable serving path for exactly this model.
- **A proven sibling package exists.** A TEI-on-Cloudron package already solved the hard parts: the
  Intel MKL `dlopen` trap (`libiomp5.so` resolved via `LD_LIBRARY_PATH`, not `ldconfig`), the
  CPU-versus-CUDA tag trap (`cpu-1.9`, not the bare `:1.9` CUDA tag), the proxyAuth split, and the
  move off the privileged upstream port. Reusing and diffing against it is far lower risk than
  building from first principles.

## Rejected alternatives

### A. Reuse the existing TEI app for reranking

Rejected. TEI serves one model per process, and the operator's existing TEI app is configured to serve
an **embedding** model (`BAAI/bge-small-en-v1.5`, 384-dim, downloaded on first boot) — verified
against the running box. A dedicated reranker app is the correct topology for a two-stage
retrieve-then-rerank stack: the embeddings instance turns text into vectors for storage and recall,
and the reranker instance scores a query against a shortlist. They are separate models and separate
apps.

### B. A Python FlagEmbedding / sentence-transformers stack (Shape B)

Rejected as the primary design; reserved only as a fallback. It works, but it is a multi-gigabyte
torch stack with a `dlopen`-heavy runtime, a worse cold-start, and a larger image than the TEI binary.
TEI can serve this exact model on `cloudron/base`, so the heavier stack buys nothing here. It would
only be revisited if TEI were empirically unable to serve the model on the base for some reason
discovered during the build (none found).

## Consequences

- The image carries ~2.27 GB of weights (a single `model.safetensors`), making the final image roughly
  5 GB. Pushes will be large and may need a re-push after an EOF (field guide gotcha #21).
- First boot is fast and offline because there is no download, which keeps the app inside Cloudron's
  health grace window (field guide gotcha #5).
- The package is amd64-only: the upstream TEI CPU build bundles Intel MKL and has no arm64 CPU image.
- `memoryLimit` is sized for fp32 weights resident in RAM (start at 4 GiB, tune against measured RSS).
