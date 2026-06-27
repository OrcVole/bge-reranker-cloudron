# BGE Reranker for Cloudron

A private, self-hosted **reranking API** for Cloudron. It serves
[`BAAI/bge-reranker-v2-m3`](https://huggingface.co/BAAI/bge-reranker-v2-m3) (a multilingual
XLM-RoBERTa cross-encoder, Apache-2.0) using Hugging Face
[Text Embeddings Inference (TEI)](https://github.com/huggingface/text-embeddings-inference), the
production-grade Rust server. The model weights are **baked into the image**, so the app is ready
within seconds of install, runs fully offline, and never phones home.

This is a thin, reproducible packaging layer. It does not fork or patch TEI or the model; it adapts
only the runtime environment to Cloudron's contract.

## Why a reranker

Reranking is the second stage of a retrieve-then-rerank pipeline. A first-stage retriever (vector
search over embeddings, or keyword search) returns a shortlist of candidate passages quickly but
approximately. A cross-encoder reranker then scores each candidate jointly with the query, which is far
more accurate than first-stage similarity, and you keep the top results. It pairs naturally with an
embeddings server and a vector database.

## Install

This is a community package distributed through a versions URL.

```bash
cloudron install \
  --versions-url https://raw.githubusercontent.com/OrcVole/bge-reranker-cloudron/main/CloudronVersions.json \
  --location reranker.example.com
```

The same command installs or updates. There is no setup screen; the model is baked, so the app is
healthy within seconds.

## Quick start

1. Read the auto-generated API key. Open a Terminal for the app (the `>_` button) and run:

   ```bash
   cat /app/data/.secrets/keys.env
   ```

2. Call the reranker. Send the key as `Authorization: Bearer <key>`:

   ```bash
   curl https://reranker.example.com/rerank \
     -H "Authorization: Bearer $RERANKER_API_KEY" \
     -H 'content-type: application/json' \
     -d '{"query":"what is panda?","texts":["hi","The giant panda is a bear endemic to China."]}'
   ```

   ```json
   [{"index":1,"score":0.958},{"index":0,"score":0.0003}]
   ```

   You get a relevance score for every text, sorted best-first, with the original index. Take as many
   top results as you need.

## API

| Route | Auth | Purpose |
|-------|------|---------|
| `POST /rerank` | Bearer key | Score `texts` against a `query`. |
| `GET /info` | Bearer key | Model and server info. |
| `GET /metrics` | Bearer key | Prometheus metrics. |
| `GET /health` | open | Liveness, for platform monitoring. |
| `/docs` | Cloudron login | Interactive Swagger UI. |

`POST /rerank` request fields: `query` (string, required), `texts` (array of strings, required), and
the optional `raw_scores` (bool), `return_text` (bool), `truncate` (bool), `truncation_direction`
(`Left` or `Right`). Response: a JSON array of `{index, score}` (plus `text` when `return_text` is
true), sorted best-first.

Note: TEI's `/rerank` has **no server-side `top_n`**. It returns a score for every text; slice the top
results client-side.

## Security and topology

Two surfaces, two security models:

- The **reranking API** (`/rerank`, `/info`, `/metrics`) is open at the network layer and protected by
  the app's own Bearer key. An unauthenticated request returns TEI's own `401`, never an SSO redirect,
  which is what lets non-browser clients integrate.
- The **Swagger docs** (`/docs`) are placed behind Cloudron single sign-on (the `proxyAuth` addon,
  path-scoped to `/docs`).
- `/health` is open and unauthenticated so the platform can monitor the app.

Do not widen the SSO wall to cover `/rerank`; it would redirect every client to a login page. The key
is generated once on first run, stored at `/app/data/.secrets/keys.env`, injected through the
environment (so it never appears in the process table), and never written to the logs. It is stable
across updates and restores, so integrators configure it once.

## Configuration

The model is fixed (baked). Everything else is tunable through the app's Environment.

| Variable | Default | Meaning |
|----------|---------|---------|
| `RERANKER_NUM_THREADS` | capped CPU count | Inference and tokenization threads. More threads is faster but uses more memory. |
| `RERANKER_MAX_THREADS` | `4` | Upper bound applied to the auto-detected thread count. |
| `RERANKER_MAX_BATCH_TOKENS` | `4096` | Token budget per batch. Also caps the effective single-input length (longer query plus passage is truncated). |
| `RERANKER_HTTP_PORT` | `8080` | Listener port. |
| `RERANKER_SERVED_MODEL_NAME` | `BAAI/bge-reranker-v2-m3` | Name reported by `/info`. |
| `RERANKER_DTYPE` | unset | Override the compute dtype (advanced). |
| `RERANKER_AUTO_TRUNCATE` | on (TEI default) | Truncate over-length inputs rather than rejecting them. |

### Memory and threads

Memory scales with the thread count and the batch token budget. For this model on CPU, each thread
carries roughly half a gigabyte of working memory, so the package caps the default thread count (4)
and bounds the MKL/OpenMP pool, and it sets a frugal `max_batch_tokens` (4096) because TEI's upstream
default would allocate gigabytes of attention scratch during warmup and OOM the app on first boot.

With the defaults the app idles around 2 GB and `memoryLimit` is set to 4 GiB. To rerank longer
passages or run more threads, raise `RERANKER_MAX_BATCH_TOKENS` and/or `RERANKER_NUM_THREADS` and
raise the app's memory limit to match.

### Slow or large batches

Cloudron's reverse proxy cuts a request at about 60 seconds. A very large batch of long passages on CPU
can approach that. Keep batches modest, or call the app from another app on the same box over
`http://<internal-name>:8080/rerank` to bypass the external proxy for long internal calls. See
[`docs/INTEGRATIONS.md`](docs/INTEGRATIONS.md).

## Build and test

```bash
test/smoke.sh          # build + run Cloudron-style + assert auth and a genuine rerank (podman; ENGINE=docker to override)
test/secret-scan.sh    # anonymity sweep over tracked files (release gate)
```

`test/smoke.sh` is the real gate: it builds the image, runs it the way Cloudron does, and asserts that
the model loads and reranks correctly on `cloudron/base` (the build linkage gate alone does not exercise
the MKL runtime that loads at first inference).

## Versioning

- `version` (manifest): this package's own semver, moves on any packaging change.
- `upstreamVersion` (manifest): the TEI server version (1.9.3), mirrors the `TEI_VERSION` build arg.
- The model is pinned by Hugging Face commit revision in the Dockerfile, with the large files verified
  by sha256 at build time.

amd64 only: the TEI CPU build bundles Intel MKL and has no arm64 CPU image.

## Licence and attribution

This package is licensed under [Apache-2.0](LICENSE). It vendors and serves third-party work, all
Apache-2.0, unmodified:

- the model [`BAAI/bge-reranker-v2-m3`](https://huggingface.co/BAAI/bge-reranker-v2-m3) (BAAI);
- the [Text Embeddings Inference](https://github.com/huggingface/text-embeddings-inference) server and
  binary (Hugging Face).

The icon is an original mark for this package (see `docs/decisions/0003-icon-neutral-original-mark.md`).
This is an unofficial community package and is not affiliated with or endorsed by BAAI, Hugging Face,
or Cloudron.
