# ADR-0004: Front TEI with an nginx immediate-health reverse proxy

- Status: accepted (rationale corrected 2026-09-25, see History)
- Date: 2026-06-27

## Context

On the box, the app restart-looped on first install. Two facts were measured:

- **TEI does not bind its HTTP port until model warmup completes** (about 35 to 45 seconds on CPU for
  this model). During that window `/health` is connection-refused, so Cloudron's health check reports
  the app as not responding. Local podman never showed this because podman does not health-check.
- At `max_batch_tokens=4096` the warmup memory peak (cache-inclusive) reached about 5.2 GB, above the
  original 4 GiB limit.

At the time we attributed the loop to the refused health check. That was wrong: Cloudron's health
check only reports status and never restarts a container. The loop was most likely an out-of-memory
kill during warmup (exit 137), with Docker restarting the killed container. See History.

## Decision

1. **Front TEI with nginx** (shipped in `cloudron/base`) so the dashboard reads healthy during warmup
   instead of not responding. nginx listens on the manifest httpPort
   (8080) and answers `GET /health` with a static 200 from the first second. Every other path is
   proxied to TEI on `127.0.0.1:8081`. The entrypoint starts nginx in the background, then
   `exec gosu cloudron tei`, so TEI is the container's main process (PID 1).
2. **Raise `memoryLimit` to 6 GiB** so the warmup peak has comfortable headroom (the operator
   confirmed ample RAM is available). In hindsight this is the change that stopped the restart loop.

## Why this is safe

- **The static `/health` cannot mask a crash.** TEI is PID 1, so if it ever exits the container exits
  and is restarted, regardless of what nginx reports. The static 200 only bridges the startup
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

- **Raise the memory limit only.** Rejected at the time on the belief that the refused health
  connection caused the loop. Corrected 2026-09-25: the memory raise alone most likely would have
  stopped the loop; without the shim the dashboard would simply show the app as not responding for
  the warmup window.
- **Lower `max_batch_tokens` so warmup is fast enough to fit the health grace.** Warmup at
  `max_batch_tokens=1024` is about 6 seconds, but the grace is roughly 11 seconds and varies with the
  box's CPU allotment, so this is fragile and also caps the effective input length more than wanted.
  The nginx shim decouples health from warmup entirely and is the field guide's sanctioned pattern
  (section 9, Appendix B.4). (Corrected 2026-09-25: there is no restart at the end of a grace window,
  only a status report, so this alternative was addressing a problem that did not exist.)
- **A Cloudron health-grace knob.** The manifest does not expose one.

## Consequences

- The image carries an `nginx.conf` and runs two processes (nginx helper plus TEI main). A genuine
  multi-process supervisor was judged unnecessary for one long-lived helper whose death is tolerable
  (the health check would then report the app as not responding; nothing restarts it automatically).
- The smoke test now asserts `/health` returns 200 during warmup (before TEI logs "Ready"), so this
  regression is caught locally in future.

## History

- **2026-06-27.** Accepted, with the rationale that a refused `/health` during warmup made Cloudron
  kill and restart the container.
- **Corrected 2026-09-25.** That rationale was false. Cloudron's health monitor never restarts a
  container (confirmed by Cloudron staff on the Cloudron forum); it only reports status on the
  dashboard. The first-install loop was most likely an out-of-memory kill during warmup (exit 137,
  against a ~5.2 GB peak and a 4 GiB limit), restarted by Docker, and fixed by the memory raise in the
  same commit. The decision stands: the shim is harmless, keeps the dashboard showing the app healthy
  during warmup, and `/rerank` returns 502 until TEI is ready.
