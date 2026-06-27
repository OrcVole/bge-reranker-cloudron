# Lessons learned: packaging bge-reranker-v2-m3 for Cloudron

The retrospective, synthesized from the running notes in `docs/THINGS-LEARNED.md` and
`docs/PACKAGING-NOTES.md`. It records what was hard, what was surprising, and what the next person
should carry forward.

Status at the time of writing: the package builds, passes every local gate (build linkage, a genuine
`/rerank` smoke, secret scan, read-only and runs-as and CPU-only conformance), and the image is pushed
to the registry pinned by digest. The box phases (a stranger install from the versions URL, update and
backup/restore survival, and live stack integration) are pending the registry package being made
public.

## The headline

Empirical verification did real work here, exactly as the prime directive promised. It corrected the
brief twice and it uncovered a memory failure that no document would have shown. The most valuable hour
of the effort was spent watching a container OOM and sweeping the parameter space, not reading.

## 1. Reuse beat reinvention

The package is a thin specialisation of an existing, proven TEI-on-Cloudron package. That package had
already paid for the hard parts: the Intel MKL and `libiomp5` dlopen handling, the CPU versus CUDA tag
trap, the auth split, and the move off the privileged port. The reranker package changed exactly three
things: it bakes the model instead of downloading it, it points `--model-id` at the baked path, and its
smoke test does a genuine `/rerank` instead of an embed. Starting from a working sibling and diffing was
far cheaper than building from the field guide alone. The lesson generalises: when a near-neighbour
package exists, specialise it and keep the diff small.

## 2. The brief was wrong twice, and the source settled it

- The brief said the model is MIT licensed. The model card and the Hugging Face API both say
  Apache-2.0. One request to the raw card frontmatter settled it. This mattered because the licence
  drives the package's own `LICENSE` file and attribution.
- The brief listed `top_n` as a `/rerank` field. TEI has no `top_n`; it returns a score for every text
  and the client slices. This was confirmed against the TEI source and OpenAPI, not assumed.

Neither error was the brief author being careless; both are the ordinary drift of facts written down
once and not re-checked. The discipline that catches them is cheap: verify a fact against its source
before you depend on it, and record the correction.

## 3. The memory trap (the centerpiece)

The model loaded and the first inference ran, then the container died during warmup with no error line,
only exit 137. The naive reading is "raise the memory limit". That reading was wrong, and chasing it
would have produced a package that needs eight gigabytes and still OOMs on a large host.

Two compounding causes, both found by sweeping the parameter space against the running container:

- TEI warms up by running a batch up to `max_batch_tokens` (default 16384) at the model's maximum
  sequence length. This model has an 8192-token context, and attention memory is quadratic in sequence
  length, so the warmup tried to allocate many gigabytes of attention scratch and was killed. The fix
  is a frugal `max_batch_tokens` default (4096), not more memory.
- Memory also scaled with the thread count, because the MKL math runtime sizes its thread pool to the
  visible host cores and each thread carries roughly half a gigabyte of working memory for this model.
  Bounding the framework's own `RAYON_NUM_THREADS` was not enough; the MKL and OpenMP pools had to be
  bounded too (`OMP_NUM_THREADS`, `MKL_NUM_THREADS`), and the default thread count capped, because a
  Cloudron app can land on a host that imposes no per-app CPU limit.

The lesson worth carrying: when an ML server OOMs, the lever is often to cap concurrency and batch size
so memory is predictable on any host, not to raise the limit. And size the warmup, because warmup is
the first-boot memory spike that decides whether the app ever reports healthy.

## 4. Baking a model can be clean

The model was baked with `curl` from the pinned `resolve/<commit>` URL and verified with `sha256sum -c`
against the Git-LFS content hashes. No Python, no pip, no download cache baked into a layer. The 5.2 GB
image is all real weight. Ordering the model download before the entrypoint copy means editing the
entrypoint rebuilds in seconds without re-downloading two gigabytes. A small build gotcha cost a few
minutes: a shell heredoc does not mix with backslash line-continuations under buildah, so the checksum
list is fed with `printf | sha256sum -c -`.

## 5. The gates earned their keep

The build linked and the binary reported its version, but neither touched the MKL runtime that loads at
first inference, and neither ran the warmup. Only a runtime smoke test that performs a genuine `/rerank`
surfaced the warmup OOM. The read-only conformance run (read-only rootfs, tmpfs `/run` and `/tmp`)
proved the app writes nothing outside `/app/data`, and a write to `/app/code` correctly failed with
EROFS. The secret scan stayed green throughout. Cheapest gate first, and the one that proves real
behaviour is the one that found the real bug.

## 6. Anonymity is a clean split, not a scrub

The package has a public identity (the packager handle, the public repository, a noreply email) and a
private context (the operator's real domains, the private mirror, local paths). Keeping the two apart is
mechanical: a gitignored list of forbidden strings, box-specific working docs gitignored, and a secret
scan run before any push. The public record of what was verified lives in the packaging notes; the
box-specific evidence lives in a local-only status file. There was nothing to scrub because the private
strings never entered a tracked file.

## 7. Process notes

- The box's API was reachable only with the shell sandbox disabled, because the box is on a private
  domain not in the sandbox allowlist. General egress to the public registries worked. Worth knowing so
  a connectivity failure is not mistaken for an outage.
- TEI logs an ERROR about a missing `onnx/model.onnx` before falling back to the Candle backend for a
  safetensors-only model. It reads like a failure and is not one. A lower log level upstream would save
  confusion.

## 8. Still pending

- A stranger install from the public versions URL on a throwaway subdomain, then update survival (the
  key byte-identical across an image update) and backup and restore survival (the entrypoint takes the
  existing-key path, ownership and mode re-asserted).
- Live integration with at least one real consumer on the box (an n8n HTTP node or a Dify rerank model
  provider).
- Making the registry package public is a one-time manual action in the registry UI with no API, so it
  is the gate in front of all of the above.

## Verdict

A clean, conformant package built as a thin specialisation of a proven sibling. The one genuinely new
problem, the warmup memory trap, was an empirical find that the documentation could not have given, and
it is now fixed and documented for the next long-context model someone tries to serve on CPU.
