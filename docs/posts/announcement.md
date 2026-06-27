<!--
DRAFT announcement post. Persona: OrcVole. Modeled on the operator's TEI announcement house style.
Anonymity: verified - upstream + github.com/OrcVole public URLs only; no private hosts, emails, or keys.
BLOCKED ON INPUT: confirm the target venue and any venue-specific template/format before posting.
SCREENSHOTS: attach the Swagger /docs page and the app tile icon.
-->

# BGE Reranker (bge-reranker-v2-m3), packaged for Cloudron

A community package for a private, self-hosted **reranking API**. It serves `BAAI/bge-reranker-v2-m3`
(a multilingual cross-encoder, Apache-2.0) on Hugging Face Text Embeddings Inference (TEI), with the
**model weights baked into the image** so it is ready in seconds and runs fully offline. It is the
reranking tier of a self-hostable retrieval stack: retrieve a shortlist by vector or keyword search,
then rerank it with a cross-encoder for much better ordering.

- Package: <https://github.com/OrcVole/bge-reranker-cloudron>
- Upstream server: <https://github.com/huggingface/text-embeddings-inference>
- Model: <https://huggingface.co/BAAI/bge-reranker-v2-m3>

## TL;DR

Install from the versions URL; the API key is generated for you on first run; send
`POST /rerank` with a query and a list of candidate texts and get a relevance score for each, sorted
best-first. It is **API-only (no web UI)**, **amd64-only** (the TEI CPU build bundles Intel MKL), and
verified on Cloudron 9.x with a genuine rerank on the assembled base image. It pairs directly with the
TEI embeddings and Qdrant packages to complete a pure-Rust retrieve-then-rerank pipeline.

```
cloudron install \
  --versions-url https://raw.githubusercontent.com/OrcVole/bge-reranker-cloudron/main/CloudronVersions.json \
  --location reranker.example.com
```

---

## For potential users

**What reranking is.** A first-stage retriever (embeddings plus a vector database, or keyword search)
is fast but returns an approximate shortlist. A cross-encoder reranker reads the query and each
candidate passage together and scores how well they match, which is much more accurate than first-stage
similarity. You keep the top few. It is the cheapest large quality win you can add to a RAG pipeline.

**What you see when you open it.** This is a service, not a website. Opening the app's domain shows a
short landing page that says what the API is and how to call it (no login needed to read it). The
interactive Swagger docs are at `/docs` (behind your Cloudron login), and that is where the dashboard
"Open" button goes. You use the reranker by calling `POST /rerank` with your API key (read it once from
the app's Terminal with `cat /app/data/.secrets/keys.env`); the response is a list of `{index, score}`,
sorted best first, for your code to consume, not a page for people to read.

**What you can do with it.**
- Sharpen any RAG or search result: retrieve 50 candidates, rerank, keep the best 5 before you send
  them to the LLM.
- Give n8n, Dify, or your own code a private reranking backend, so your documents never leave the box.
- Rerank multilingually: the model handles many languages.

**Synergy with other Cloudron apps.** This is one tier of a stack you can run entirely on Cloudron:

| App | Role |
| --- | --- |
| **TEI** (embeddings) | Text -> vectors for first-stage retrieval |
| **Qdrant** | Stores the vectors, does similarity search |
| **BGE Reranker** (this) | Reorders the shortlist by true relevance |
| **Ollama** | The LLM that answers over the reranked context |
| **Open WebUI / Dify / n8n** | The app or flow that ties retrieve -> rerank -> generate together |

**Good defaults.** The reranking API is protected by a strong key generated on first run and injected
through the environment (never in the process table); `/health` stays open for monitoring; the Swagger
docs sit behind Cloudron single sign-on. The key lives under `/app/data`, so the backup covers it and a
restore brings the same key back. The model is baked, so there is no first-boot download and nothing
phones home.

**Caveats:** no web UI; amd64 only; CPU inference (fast enough for reranking shortlists, not for huge
batches); the default caps effective input length for memory safety (tunable).

---

## For other packagers

This package is the sibling of the TEI embeddings package, specialised to a reranker with the model
baked in. The MKL/`libiomp5` runtime copy and the auth split are reused from that package unchanged;
the new ground was the baked model and the memory behaviour.

**What helped.**
- **Baking the model with `curl` from the pinned `resolve/<commit>` URL plus a `sha256sum -c` gate.**
  No Python, no pip, no download cache baked into a layer; the 5.2 GB image is all real weight. Ordering
  the model `RUN` before the `start.sh` COPY means entrypoint edits rebuild in seconds.
- A **runtime smoke test that does a genuine `/rerank`** (panda passage outranks "hi"), which is the
  only thing that exercises the MKL math runtime that loads at first inference.
- The usual `/app/data`-only state, read-only rootfs proof (a write to `/app/code` fails EROFS), and a
  build-time linkage gate.

**What was difficult (and new).**
- **TEI's default warmup OOM-kills a long-context reranker.** TEI warms up by running a batch up to
  `max_batch_tokens` (default 16384) at the model's maximum sequence length (8192 here). The attention
  scratch is O(sequence^2), so warmup tried to allocate many gigabytes and the container was
  OOM-killed during "Warming up model" with no error line, just exit 137. Fix: pass a frugal
  `--max-batch-tokens` (4096) by default, tunable up with the memory limit.
- **Bounding the framework's thread count is not enough; MKL/OpenMP must be bounded too.** The MKL
  runtime (via `libiomp5`) sizes its pool to the visible host cores regardless of `RAYON_NUM_THREADS`,
  and each thread carried roughly half a gigabyte for this model. On a box with no per-app CPU limit
  that re-inflates memory and OOMs warmup. Fix: cap the default thread count and set
  `OMP_NUM_THREADS`/`MKL_NUM_THREADS` alongside the framework variable. Lesson: cap threads, do not
  just raise the memory limit.
- A small build gotcha: a shell heredoc does not mix with backslash line-continuations under buildah;
  feed checksums with `printf '%s  %s\n' ... | sha256sum -c -`.

**Compatibility with other apps.** API-key auth on the data plane and SSO only on `/docs`, so a sibling
app authenticates with a key and gets TEI's own 401 (not a login redirect) on a bad key. Internal
callers can hit `http://<internal-name>:8080/rerank` to bypass the external proxy for long calls.

---

## For the Cloudron maintainers

- **`iconUrl` couples to the `minBoxVersion` floor (same as the TEI/Qdrant packages).** A versions-url
  manifest must include `iconUrl`, which forces `minBoxVersion >= 9.1.0`, even for an app that runs on
  8.3. Please document or decouple.
- A documented **podman path for `cloudron versions add`** (or an `--image <registry-ref>` form) would
  remove the need to hand-build `CloudronVersions.json` on podman-only hosts.

## For the upstream developers (Hugging Face TEI, and BAAI)

- TEI's **default warmup is not safe on CPU for long-context classification models**, and the failure
  is a silent OOM (exit 137, no log). A memory-aware default `max_batch_tokens`, or a warmup that scales
  to available memory, would prevent a confusing first-boot crash.
- TEI logs **`ERROR ... onnx/model.onnx does not exist`** before falling back to Candle for a
  safetensors-only model. It reads like a failure but is the normal fallback; a lower log level would
  reduce confusion. (BAAI shipping an `onnx/` export would also let the faster ORT backend run.)
- Inherited from the embeddings package: `--hostname` defaulting to `HOSTNAME` is container-hostile,
  and an arm64 CPU image would broaden where this runs.

---

It tracks upstream TEI releases and the model revision and keeps both unmodified. BAAI, Hugging Face,
and the model names are trademarks of their owners; this is a community package, not affiliated with or
endorsed by them. Feedback, issues, and suggestions are very welcome.

#reranker #bge #text-embeddings-inference #rag #cloudron-9.1
