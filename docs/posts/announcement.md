<!--
Community package announcement post. Persona: OrcVole. Format mirrors the operator's Docling announcement.
Anonymity: verified - upstream + github.com/OrcVole public URLs only; no private hosts, emails, or keys.
SCREENSHOTS in the repo screenshots/ dir: docs.png (the Swagger /docs page), app-tile.png (the icon in
the dashboard), overview.png (a branded explainer card). A landing-page shot at / can be added too.
-->

## 🚀 BGE Reranker: community package now available

> **TL;DR:** A reranker scores how well each candidate passage answers a query, so you can reorder a
> shortlist by true relevance and keep the best few. This package serves `BAAI/bge-reranker-v2-m3` (a
> multilingual cross-encoder) on Hugging Face Text Embeddings Inference, with the **model baked into the
> image**, as a private `POST /rerank` API. It is the reranking tier of a self-hosted retrieve-then-rerank
> stack and the cheapest large quality win you can add to RAG or search. Now packaged for Cloudron and
> ready to install. Built and tested on Cloudron 9.x; unofficial and community-maintained.

### Links

- 🏠 Model card: https://huggingface.co/BAAI/bge-reranker-v2-m3
- 📦 Upstream model project: https://github.com/FlagOpen/FlagEmbedding
- 🧱 Upstream server: https://github.com/huggingface/text-embeddings-inference (TEI)
- 🧰 Cloudron package repo: https://github.com/OrcVole/bge-reranker-cloudron

No public demo to click, this is an API you self-host. Once installed, opening the app's domain shows a
small landing page explaining what it is and how to call it, and the interactive OpenAPI docs are at
`/docs` behind your Cloudron login.

---

### 📥 How to install

Community packages are not in the App Store, so install via the CLI. The published image is on GHCR and
the package ships a community versions file:

```bash
# recommended: install the published community build from the versions URL
cloudron install \
  --versions-url https://raw.githubusercontent.com/OrcVole/bge-reranker-cloudron/main/CloudronVersions.json \
  --location reranker.example.com

# or pin the prebuilt image directly
cloudron install --image ghcr.io/orcvole/bge-reranker-cloudron:1.0.0 --location reranker.example.com

# or build it yourself from the repo
git clone https://github.com/OrcVole/bge-reranker-cloudron
cd bge-reranker-cloudron
cloudron build
cloudron install --image [your-registry]/bge-reranker-cloudron:latest --location reranker.example.com
```

**Minimums:** 6 GB RAM (the model warmup peaks higher than its idle footprint; lower `RERANKER_MAX_BATCH_TOKENS`
if you want it leaner), amd64 (the TEI CPU build bundles Intel MKL), addons `localstorage` and `proxyAuth`.

**First run:** the API key is generated for you. Read it from the app's Terminal with
`cat /app/data/.secrets/keys.env` and send it as `Authorization: Bearer <key>` on `POST /rerank`. The
`/docs` Swagger UI sits behind your Cloudron login; `/health` and the landing page at `/` are open. The
model is baked into the image, so there is no first-boot download: the app reports healthy in seconds and
serves its first rerank after a brief warmup (well under a minute).

---

### 👤 For users

**Why try it:** retrieval gets you a rough shortlist; a cross-encoder reranker reads the query and each
candidate passage together and scores how well they actually match, which is far more accurate than
first-stage similarity. Retrieve 50 candidates, rerank, keep the best 5 before you send them to the LLM.
It is the highest-leverage, lowest-effort accuracy improvement you can add to a private retrieval stack,
and your documents never leave your box.

What you get out of the box:

- A **reranking API** (`POST /rerank` with a query and a list of texts, returns a relevance score for
  each, sorted best first), CPU-only, multilingual, model baked in.
- A small **public landing page** at `/` that says what the API is and how to call it, plus interactive
  OpenAPI docs at `/docs` (behind your Cloudron login).
- **Cloudron-specific wins:** the API key is generated on first run, `/health` is open for monitoring,
  `/docs` sits behind Cloudron SSO, all state lives under `/app/data` so backups cover the key, and
  updates are one click. The key is stable across update and restore (verified).

Good fit if you want a self-hosted reranking tier for RAG and semantic search (pairs directly with the
TEI and Qdrant community packages). Probably not for you if you need GPU acceleration (this build is
CPU-only) or arm64 (the TEI CPU image is amd64-only).

---

### 🧰 For packagers: what we learned

**What helped**

- **Baking the model with `curl` from the pinned `resolve/<commit>` URL plus a `sha256sum -c` gate**,
  rather than a pip/Python download. No download cache baked into a layer: the ~5.2 GB image is all real
  weight (base + the TEI binary and MKL runtime + the 2.2 GB model). Ordering the model `RUN` before the
  entrypoint copy means editing the entrypoint rebuilds in seconds without re-downloading the model.
- Reusing the sibling TEI embeddings package wholesale: the Intel MKL / `libiomp5` dlopen handling, the
  CPU-versus-CUDA tag trap (`cpu-1.9`, not the bare CUDA tag), the two-surface auth split, and the port
  move were already solved. The new ground was just baking the model and the memory behaviour.
- Putting all state under `/app/data` so the `localstorage` backup just works; a real update and a real
  backup-then-restore both brought the key back byte-identical, with mode re-asserted to `0600`.

**What was tricky and how we solved it**

- **A long model warmup makes a server restart-loop on Cloudron.** TEI does not bind its HTTP port until
  warmup finishes (tens of seconds on CPU), so `/health` is refused during warmup and the platform kills
  and restarts the container before it is ready. Local podman never caught it, because it does not
  health-check during warmup; only the box did. The fix is the field guide's nginx immediate-health shim:
  nginx answers `/health` 200 from the first second and proxies everything else to TEI internally, with
  TEI still the main process so a real crash still restarts. The runtime smoke now asserts `/health` is
  answered *during* warmup, so the regression cannot return silently.
- **nginx died on the box** with `error_log /dev/stderr` (EACCES, because the fd-2 target is root-owned
  and the app runs unprivileged) and silently never bound its port. Use the `error_log stderr` keyword
  (writes the inherited fd, no `open()`). Also podman-invisible.
- **TEI's default `max_batch_tokens` OOM-kills warmup** for this 8192-token-context model (quadratic
  attention scratch). Set a frugal default (`4096`) and cap the thread count, and bound
  `OMP_NUM_THREADS`/`MKL_NUM_THREADS`, not just the framework's own thread var, or memory balloons on a
  host with no per-app CPU limit.

**Still rough and open questions**

- Under box CPU contention the warmup stretches to ~90s. It is invisible to users (the shim keeps the app
  healthy), but a faster or memory-aware warmup upstream would be welcome.
- Whether 6 GiB can be trimmed with a lower default batch budget without hurting throughput for the common
  reranking case.

---

### 🛠️ For the Cloudron team

**Maintenance burden:** the package is a thin layer (a pinned `TEI_VERSION` build-arg, a pinned model
revision, and the manifest), so a rebump is a version bump and a re-run of the `/rerank` smoke. TEI has a
steady release cadence.

**Why it would suit the App Store:** Apache-2.0 upstream (both the model and the server), real demand
(reranking is the missing accuracy tier for self-hosted RAG), and it completes the existing TEI and Qdrant
community stack.

**Friction worth knowing about:** the `iconUrl` field couples to the `minBoxVersion 9.1.0` floor on the
versions-url channel (shared with TEI, Qdrant, Docling). And one worth a platform note: a backend that
binds its port only after a long startup warmup will restart-loop, because the health check is refused
during warmup; an immediate-health proxy works, but a documented startup grace would be friendlier.

---

### 💻 For TEI's and the model's developers

A few low-effort things that help packagers a lot:

- **Bind the listener (and answer `/health`) before warmup, or document that it comes up after.** A
  platform that health-checks during startup restart-loops the container otherwise, and the failure is a
  silent refused connection.
- **A memory-aware default `max_batch_tokens`.** The current default allocates gigabytes of attention
  scratch during warmup for a long-context model on CPU and OOM-kills first boot with no clear error.
- **Lower the log level of the ORT-backend fallback.** TEI logs `ERROR ... onnx/model.onnx does not exist`
  before falling back to Candle for a safetensors-only model; it reads like a failure but is the normal
  path. (A shipped `onnx/` export from BAAI would also let the faster ORT backend run.)
- Inherited asks: `--hostname` defaulting to `HOSTNAME` is container-hostile, and an arm64 CPU image would
  broaden where this runs.

Package source and PRs welcome here: https://github.com/OrcVole/bge-reranker-cloudron. Happy to co-maintain.

---

### 🔓 Unlocks

Once it is running, you can:

- Sharpen any RAG or search result: retrieve a shortlist, rerank, keep the best few before the LLM sees them.
- Rerank multilingually, with nothing leaving your server.
- Drop the closed Cohere or Voyage rerank APIs for an Apache-2.0 model on your own box.

### 🔗 Synergies

Pairs nicely with other Cloudron apps:

- **Reranker + TEI + Qdrant:** embed with TEI, store and search in Qdrant, then rerank the shortlist here.
- **Reranker + Ollama or Open WebUI:** answer over the reranked context.
- **Reranker + n8n or Windmill:** an HTTP node or script calls `POST /rerank` with the Bearer key (both
  verified end to end from their containers).
- **Reranker + Dify:** add it as a Text Embeddings Inference rerank model in Dify's model providers.

---

Feedback, bug reports, and "works on my install" confirmations all welcome below. 🙏
