# Things learned (running notes)

A live log kept from Phase 0 onward, not an end-of-project write-up. Each entry is tagged with its
audience so it can be lifted into the right place later:

- `[users]` - people installing and calling the reranker.
- `[packagers]` - anyone packaging an ML server or a TEI model for Cloudron.
- `[cloudron]` - feedback for the Cloudron maintainers (docs, base image, platform).
- `[upstream]` - feedback for the reranker model and the TEI server developers.

The synthesized retrospective is `../LESSONS-LEARNED.md`. This file is public and anonymized.

---

## Phase 0 - orientation

- `[packagers]` **A model card's `text-embeddings-inference` tag is the signal that TEI can serve it.**
  `BAAI/bge-reranker-v2-m3` carries that tag plus `pipeline_tag: text-classification` and an
  `XLMRobertaForSequenceClassification` architecture. That combination - a sequence-classification
  cross-encoder tagged for TEI - is exactly what TEI auto-detects and exposes on `/rerank`. Check the
  card tags before choosing a serving stack; they tell you whether the canonical, production-grade
  path exists.

- `[packagers]` **Re-verify the licence from the source, never from a brief or a table.** The project
  brief stated this model is MIT-licensed, in two places. The Hugging Face model card (and the API)
  say Apache-2.0. Licence drives the package's own `LICENSE` file and attribution, so it is not a
  detail to carry on trust. One `curl` to the raw `README.md` frontmatter settled it.

- `[packagers]` **Bake a Hugging Face model with `curl` from the `resolve/<commit>` URL plus a
  sha256 gate - no Python, no pip, no cache cruft.** The weights and tokenizers are Git-LFS objects
  whose LFS `oid` is their sha256, available from the HF tree API. Downloading the exact files from
  `https://huggingface.co/<repo>/resolve/<commit-sha>/<file>` and verifying each big file with
  `sha256sum -c` pins the content reproducibly and keeps the build dependency-light. It also avoids
  the "pip's multi-gigabyte download cache baked into a RUN layer" image-bloat trap, because the only
  bytes that land are the model files themselves.

- `[packagers]` **A dedicated app per model is the correct TEI topology.** TEI serves one model per
  process. An embeddings instance and a reranker instance are two apps, which is also the right shape
  for a two-stage retrieve-then-rerank RAG stack (embed and store, then rerank the shortlist).

- `[packagers]` **Reuse a sibling package as the template, then diff.** Specialising an existing,
  proven TEI-on-Cloudron package (already past the MKL/libiomp dlopen trap, the CPU-vs-CUDA tag trap,
  the auth split, and the port move) to a different model is far less risky than building from the
  field guide alone. The deltas here are exactly three: bake the model instead of downloading it,
  point `--model-id` at the baked path, and rewrite the smoke test's data-plane assertion from
  `/embed` to a genuine `/rerank`.

- `[users]` **This package is a reranking API, not a web page.** Visiting the app domain in a browser
  lands on Swagger docs (behind login); there is no dashboard. You call `POST /rerank` with a Bearer
  key. (Expanded in `POSTINSTALL.md`.)

## Phase 1 to 4 - build and local gates

- `[packagers]` `[upstream]` **A long-context reranker OOM-kills TEI's warmup at the default
  `max_batch_tokens`.** TEI warms the model by running a batch up to `max_batch_tokens` (default
  16384) at the model's maximum sequence length. For `bge-reranker-v2-m3` (8192-token context) the
  attention scratch is O(sequence^2) and needs many gigabytes, so the container is OOM-killed during
  "Warming up model" with no error line, only exit 137. It looks like a mysterious silent crash. The
  fix is a frugal `--max-batch-tokens` default (4096 here). Worth a note upstream: the default warmup
  is not safe on CPU for long-context classification models, and the failure is silent.

- `[packagers]` **Bound the MKL/OpenMP thread pool, not just the framework's.** TEI's CPU build uses
  Intel MKL via libiomp5, which sizes its thread pool to the visible host cores independently of
  `RAYON_NUM_THREADS`. Each thread carried roughly half a gigabyte of working memory for this model,
  so on a host with many cores and no per-app CPU limit the memory ballooned and warmup OOM'd. Set
  `OMP_NUM_THREADS` and `MKL_NUM_THREADS` (and cap the default) in addition to the framework's own
  thread variable. Memory scaled cleanly with the thread count once all three were bound.

- `[packagers]` **Size the thread cap, not just the memory limit.** It is tempting to fix an OOM by
  raising `memoryLimit`. Here the right lever was the opposite: cap the default thread count so memory
  is predictable on any host, and keep the memory limit modest. A Cloudron app may run on a box that
  imposes no CPU cgroup limit, in which case naive `nproc` sizing uses every core.

- `[packagers]` **Baking a model with `curl` + `sha256sum -c` is clean and reproducible.** The 5.24 GB
  image is all real weight (base + binary + 2.2 GB model), with no download-cache cruft in the layers,
  because the only bytes written are the model files. Ordering the model `RUN` before the `start.sh`
  COPY means entrypoint edits rebuild in seconds without re-downloading the model.

- `[packagers]` **Dockerfile gotcha: a shell heredoc does not mix with backslash continuations under
  buildah.** `sha256sum -c - <<'SHA' ... SHA` inside a `RUN ... \` block fails to parse
  ("unterminated heredoc"). Feed the checksums with `printf '%s  %s\n' SHA FILE ... | sha256sum -c -`
  instead.

- `[packagers]` **The runtime smoke test earned its keep.** The build linked and `--version` ran, but
  the first real inference is where the model actually loads and the warmup runs; that is where the
  OOM surfaced. A genuine `/rerank` (not a `/health` ping) was required to see it.

- `[upstream]` **TEI tries the ONNX Runtime backend first and logs an ERROR when the model ships only
  safetensors**, then falls back to Candle and works. The ERROR ("`onnx/model.onnx` does not exist")
  reads like a failure but is the normal fallback. A clearer log level would save confusion.

## Phase 6 - box deploy (what only the box surfaced)

- `[packagers]` `[cloudron]` **A server that binds its port only after a long warmup restart-loops on
  Cloudron, and local podman will not catch it.** TEI does not listen until model warmup finishes
  (tens of seconds on CPU), so `/health` is refused during warmup and Cloudron restarts the container
  before it is ready. podman does not health-check during warmup, so the local smoke passed while the
  box looped. The fix is the field guide's nginx immediate-health shim (answer `/health` 200 at once,
  proxy the rest to the backend, keep the backend as PID 1 so a real crash still restarts). Lesson:
  the runtime smoke must include "is `/health` answered during warmup", not just "does it answer once
  ready". The package's smoke now asserts exactly that.

- `[packagers]` **`error_log /dev/stderr` breaks nginx when it runs as a non-root user on the box.**
  `open("/dev/stderr")` is denied because the fd-2 target is root-owned, and nginx then fails to start
  with no obvious symptom except a refused port. Use the `error_log stderr` keyword (writes the
  inherited fd, no `open()`), which is the standard container pattern. This reproduced only on the box,
  not under rootless podman, because the fd ownership differs. A second case of "the box wins".

- `[packagers]` **Capture the real exit code of a backgrounded box command.** A wrapper that ends in
  `tail` reports the tail's exit status, so a failed `cloudron install` looked like success more than
  once. End the wrapper with `ec=$?; ...; exit $ec`.

- `[packagers]` **Measure warmup memory, not just idle.** Idle was ~3 GB but the warmup peak reached
  ~5.2 GB at the default batch size, which is what actually decides whether first boot OOMs. Size the
  memory limit (and the batch budget) to the warmup peak, with headroom.
