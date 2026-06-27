# Plan and progress

The phased plan, ratified against what was found in Phase 0, kept as a living checklist. Each done
item carries a one-line evidence note. Gates must be green before an item counts as done. This file is
public and anonymized; box-specific evidence is in the gitignored `STATUS.md`.

Effort tags: max (full reasoning + empirical verification), high, medium, low.

---

## Phase 0 - Orientation, reconnaissance, plan ratification (max)

- [x] 0.1 Read the canon: brief, field guide v0.1.2 (read in full), Cloudron AI-agent packaging skill
      (installed at `~/.agents/skills/cloudron-app-packaging`, read). Base `cloudron/base:5.0.0`, box
      9.x confirmed.
- [x] 0.2 Preconditions: cloudron CLI present and box reachable (only with the shell sandbox
      disabled); podman rootless is the build engine; skopeo present; both token files readable. GHCR
      login deferred to Phase 5. Docker socket unreachable (not needed).
- [x] 0.3 Inventory: no third-party reranker Cloudron package exists; `OrcVole/bge-reranker-cloudron`
      is an empty stub to populate. Existing `tei` app serves embeddings (`bge-small-en-v1.5`),
      confirming a dedicated reranker app is correct. `hwdsl2/docker-embeddings` studied (two-process
      rerank, first-boot download, auto Bearer key).
- [x] 0.4 ADR-0001 ratified (TEI Shape A + baked model; both alternatives rejected with empirical
      reasons). ADR-0002 added (licence Apache-2.0, correcting the brief).
- [x] 0.5 Repo skeleton: AGENTS.md, docs/decisions/, docs/PACKAGING-NOTES.md, docs/THINGS-LEARNED.md,
      docs/PLAN.md, .gitignore, .dockerignore, .anonymize-list, LICENSE.
- [x] 0.6 Remotes wired (origin GitHub, mirror Forgejo); `git ls-remote` exit 0 on both (empty
      stubs), no push. Tokens via an inline credential helper, never in URLs or echoed.

## Phase 1 - The image: TEI binary + baked reranker (max)

- [x] 1.1 Dockerfile Shape A built; linkage gate green (`ldd` clean, `--version` runs); TEI `cpu-1.9`
      and base both pinned by digest; MKL + libiomp5 via `cp -L` + `LD_LIBRARY_PATH`.
- [x] 1.2 Model baked by curl from the pinned revision; three LFS files pass `sha256sum -c`; config
      architecture check passes; offline + telemetry-off; files 0644 (no fat chmod layer). Image 5.24 GB.
- [x] 1.3 start.sh: ownership first; idempotent key seed (0600 in 0700, re-asserted every boot);
      `--hostname 0.0.0.0`; offline; caches under /app/data; cgroup-sized + capped threads (MKL/OMP
      bounded); `exec gosu cloudron`. Facts echoed, key never. Verified in smoke + read-only runs.
- [x] 1.4 `CMD` not `ENTRYPOINT`; `.dockerignore` keeps context minimal; image secret scan clean.

## Phase 2 - Manifest, auth topology, health (max)

- [x] 2.1 CloudronManifest.json written: id `io.github.orcvole.bgereranker`, httpPort 8080, addons
      localstorage + proxyAuth `/docs`, memoryLimit 4 GiB (verified fits), healthCheckPath `/health`,
      optionalSso, minBoxVersion 9.1.0, checklist + postInstall, iconUrl/mediaLinks.
- [~] 2.2 `/rerank` returns TEI's own 401 without/with-wrong key (verified locally, not a 302). No
      `supportsBearerAuth` on the wall. proxyAuth-on-`/docs` SSO redirect to be confirmed on the box.
- [x] 2.3 `/health` returns 200 as soon as the listener binds, unauthenticated; ~50s warm boot
      locally with the baked model (no download). Confirm grace window on the box.
- [x] 2.4 POSTINSTALL.md + checklist: "reranking API, not a web page"; how to read the key; the Bearer
      header; copy-paste `/rerank` curl; `/docs` location.

## Phase 3 - Icon + store metadata (high)

- [x] 3.1 Original neutral icon authored (`logo-source.svg` -> `logo.png` 512x512, 8-bit); BAAI/HF
      marks avoided for trademark clarity (ADR-0003); `iconUrl` set.
- [x] 3.2 DESCRIPTION.md, CHANGELOG.md (bracket format), POSTINSTALL.md, README.md all done.

## Phase 4 - Local gates (max)

- [x] 4.1 Build linkage gate green (in the Dockerfile build).
- [x] 4.2 test/smoke.sh PASS: runs as cloudron; key 64 at mode 600; `/health` 200 no-key; `/rerank`
      401 no-key and wrong-key; genuine ranking with key (panda 0.96 > hi 0.0003); key absent from logs.
- [x] 4.3 test/secret-scan.sh clean over tracked files.
- [x] 4.4 Read-only rootfs boots + reranks; EROFS on `/app/code`; runs as cloudron; 0 CUDA libs;
      Candle CPU backend.

## Phase 5 - Publish the image (high)

- [x] 5.1 Pushed to ghcr.io/orcvole/bge-reranker-cloudron; registry digest
      `sha256:3c33f73d0d21b7f08b867a9d8d935a0ebba1b95d74f6598d8a3a10f38fe2c8c3` (skopeo == digestfile);
      `dockerImage` pinned in manifest and versions file.
- [~] 5.2 BLOCKED ON OPERATOR: GHCR package is still private (anonymous pull `unauthorized`). No API to
      flip it; the operator must set it Public in the GitHub Packages UI. Then verify with a logged-out pull.
- [x] 5.3 CloudronVersions.json generated (inlined manifest, contactEmail, mediaLinks, bracket
      changelog); version-entry and manifest keys match the proven TEI reference exactly.

## Phase 6 - Deploy + box gates (max)

- [ ] 6.1 Stranger install on a throwaway subdomain from the versions URL; healthy; icon; `/docs`
      behind login; `/rerank` serves with the key.
- [ ] 6.2 Update survival (key sha256 byte-identical).
- [ ] 6.3 Backup/restore survival ("existing key found" path; ownership/mode re-asserted).
- [ ] 6.4 Promote to the real target; re-run 6.1 there; uninstall throwaways.

## Phase 7 - Stack integration (max)

- [~] 7.1 Mapping done for every stack app (n8n, Dify, agentgateway, Open WebUI, LibreChat, Qdrant,
      TEI, Docling, Langfuse, Ollama, rustfs/MinIO). Live end-to-end test (n8n HTTP and/or Dify rerank
      provider) pending box deploy.
- [x] 7.2 docs/INTEGRATIONS.md: copy-paste config per app; the TEI-native vs Cohere `/v1/rerank`
      distinction; the ~60s proxy-timeout and localhost-only-within-container notes.

## Phase 8 - Documentation deliverables (max)

- [x] 8.1 docs/THINGS-LEARNED.md kept current from Phase 0, segmented by audience (users, packagers,
      cloudron, upstream).
- [x] 8.2 LESSONS-LEARNED.md synthesized (box phases noted as pending).
- [~] 8.3 Announcement + application-request posts scaffolded in docs/posts/ (modeled on the operator's
      TEI announcement and Langfuse wishlist styles). BLOCKED ON OPERATOR: confirm target venue/template.

## Phase 9 - Release hygiene + push (high)

- [ ] 9.1 Final anonymity sweep; local-only docs gitignored; tag a release; push to both remotes.
- [ ] 9.2 Sign-off: re-run the gate ladder; update this file with evidence; hand-off summary.

---

## Gate ladder (cheapest first; a change is not done until its gate is green)

1. build linkage gate → 2. smoke.sh (genuine rerank + key-not-in-logs) → 3. secret scan →
4. read-only / runs-as / CPU-only → 5. update survival (key sha256 identical) →
6. backup/restore survival ("existing key found") → 7. anonymous pull by digest →
8. stranger install on a throwaway, then uninstall. Update and restore are separate tests.
