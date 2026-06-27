# ADR-0004: Front TEI with an nginx immediate-health reverse proxy

- Status: accepted
- Date: 2026-06-27

## Context

On the box, the app restart-looped on first install. The cause, confirmed by measuring locally:
**TEI does not bind its HTTP port until model warmup completes** (about 35 to 45 seconds on CPU for
this model). During that window `/health` is connection-refused, so Cloudron's health check fails and
the platform kills and restarts the container roughly every 11 seconds, far short of warmup, an
infinite loop. Local podman never caught this because podman does not health-check during warmup; only
the box did.

A second, compounding factor: at `max_batch_tokens=4096` the warmup memory peak (cache-inclusive)
reached about 5.2 GB, close to the original 4 GiB limit, so warmup was also at risk of an OOM kill.

## Decision

1. **Front TEI with nginx** (shipped in `cloudron/base`). nginx listens on the manifest httpPort
   (8080) and answers `GET /health` with a static 200 from the first second. Every other path is
   proxied to TEI on `127.0.0.1:8081`. The entrypoint starts nginx in the background, then
   `exec gosu cloudron tei`, so TEI is the container's main process (PID 1).
2. **Raise `memoryLimit` to 6 GiB** so the warmup peak has comfortable headroom (the operator
   confirmed ample RAM is available).

## Why this is safe

- **The static `/health` cannot mask a crash.** TEI is PID 1, so if it ever exits the container exits
  and Cloudron restarts it, regardless of what nginx reports. The static 200 only bridges the startup
  warmup, when TEI is alive but not yet listening.
- **During warmup the app reports healthy but `/rerank` returns 502** until TEI binds its port. This is
  acceptable for a sub-minute, one-time first boot. After "Ready", nginx proxies `/rerank` to TEI and
  the Bearer auth and 401 behaviour are unchanged (verified: a keyless `/rerank` returns TEI's own 401,
  not nginx's 502, once TEI is up).
- **The topology is unchanged.** Cloudron's `proxyAuth` wall on `/docs` sits in front of the container,
  so SSO still guards `/docs` before nginx sees the request. nginx forwards the `Authorization` header
  to TEI unchanged.
- **Read-only filesystem respected.** All nginx scratch (pid, temp paths) is under `/run` (a tmpfs),
  created and owned by the entrypoint; nginx logs to stderr; access log off.

## Alternatives considered

- **Raise the memory limit only.** Does not fix the restart loop, because the loop is caused by the
  refused health connection during warmup, not (only) memory.
- **Lower `max_batch_tokens` so warmup is fast enough to fit the health grace.** Warmup at
  `max_batch_tokens=1024` is about 6 seconds, but the grace is roughly 11 seconds and varies with the
  box's CPU allotment, so this is fragile and also caps the effective input length more than wanted.
  The nginx shim decouples health from warmup entirely and is the field guide's sanctioned pattern
  (section 9, Appendix B.4).
- **A Cloudron health-grace knob.** The manifest does not expose one.

## Consequences

- The image carries an `nginx.conf` and runs two processes (nginx helper plus TEI main). A genuine
  multi-process supervisor was judged unnecessary for one long-lived helper whose death is tolerable
  (it just fails the health check and restarts).
- The smoke test now asserts `/health` returns 200 during warmup (before TEI logs "Ready"), so this
  regression is caught locally in future.
