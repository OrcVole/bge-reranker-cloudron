# ADR-0002: License the package Apache-2.0

- Status: accepted
- Date: 2026-06-27

## Context

The package must carry a licence. The instruction was to use "the same licence as the application."
The project brief asserted, in two places, that the model `BAAI/bge-reranker-v2-m3` is MIT-licensed.

## Decision

License this package **Apache-2.0**, and ship a `LICENSE` file with the Apache License 2.0 text.

## Why

Empirical check overrides the brief. The model's Hugging Face card YAML frontmatter says
`license: apache-2.0`, and the HF API `cardData.license` and tags agree. So the brief's "MIT" is a
factual error, corrected here and in `docs/PACKAGING-NOTES.md`.

This resolves the licence instruction with no ambiguity, because both candidate "applications" are
Apache-2.0:

- the reranker model `BAAI/bge-reranker-v2-m3` — Apache-2.0;
- the TEI server whose binary this package vendors — Apache-2.0.

Either reading yields Apache-2.0, which is also the licence the sibling TEI package uses.

## Attribution obligations

The image vendors third-party Apache-2.0 artifacts (the TEI `text-embeddings-router` binary and its
MKL runtime) and the Apache-2.0 model weights. Apache-2.0 requires preserving copyright and licence
notices for redistributed material. The package therefore:

- keeps its own `LICENSE` (Apache-2.0);
- attributes TEI (Hugging Face, Apache-2.0) and the model (BAAI, Apache-2.0) in `README.md` and the
  image `LABEL org.opencontainers.image.licenses="Apache-2.0"`;
- does not relicense or patch either upstream; the package is a thin adaptation layer.

## Consequences

- `LICENSE` is Apache-2.0.
- No copyleft obligations; Apache-2.0 is permissive and compatible with redistribution as a Cloudron
  image.
