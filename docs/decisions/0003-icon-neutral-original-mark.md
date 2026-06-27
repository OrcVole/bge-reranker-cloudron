# ADR-0003: Use an original neutral icon, not the BAAI/FlagEmbedding or HuggingFace mark

- Status: accepted
- Date: 2026-06-27

## Context

The package needs a square `logo.png` for the Cloudron store and dashboard. The application served is
the BGE reranker, so the obvious candidate mark is the BGE / FlagEmbedding / BAAI logo. The brief asked
to source the canonical mark from upstream and verify its usage/licensing, and to fall back to a
defensible neutral alternative if the canonical mark is not cleanly usable. It also forbade using
HuggingFace's own brand to represent this third-party package.

## Decision

Ship an **original, neutral icon** authored for this package (`logo-source.svg`, rendered to
`logo.png`, 512x512), licensed under the package's Apache-2.0. Do not bundle the BAAI, FlagEmbedding,
or HuggingFace marks.

## Why

- **Trademark, not copyright, is the issue.** The FlagEmbedding code is permissively licensed, but a
  project or organization logo (BAAI / FlagEmbedding) is a brand/trademark whose reuse to represent an
  unofficial third-party package is not clearly granted by the code licence. For a public package that
  a stranger installs and that aims at possible official Cloudron adoption, an unverifiable trademark
  is a liability.
- **Self-authored means cleanly licensable.** An original mark is unambiguously ours to ship under
  Apache-2.0, with no attribution or trademark question.
- **It still represents the function honestly.** The icon depicts a ranked list of candidate passages
  with the best match promoted to the top by an arrow: that is exactly what a reranker does. It does
  not impersonate any upstream brand.

## The mark

A rounded-square tile with an indigo-to-violet gradient. Inside, four rounded bars stand for candidate
passages, fading down by relevance; the top bar is amber (the promoted best match). An amber upward
arrow signifies the rerank lifting the best result to the top. Rendered with ImageMagick from the
checked-in SVG source.

## Consequences

- `logo.png` and `logo-source.svg` are original assets under the package licence.
- `iconUrl` points at the raw `logo.png` on the public repo's main branch.
- If the Cloudron maintainers or BAAI later prefer the official BGE mark, swapping `logo.png` is a
  one-line manifest-neutral change (a new package `version`, same topology).
