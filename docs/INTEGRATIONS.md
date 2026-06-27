# Integrations

How apps in a self-hosted AI stack consume this reranker. This file is public and anonymized: replace
`reranker.example.com` with your app's real domain and `YOUR_KEY` with the value from
`cat /app/data/.secrets/keys.env`.

## The one thing to know first: two reranking dialects

There are two incompatible HTTP shapes for "reranking", and apps expect one or the other:

- **TEI-native `/rerank`** (what this app speaks): `POST /rerank` with
  `{"query": "...", "texts": ["...", "..."]}`, returns `[{"index", "score"}]` sorted best-first. No
  server-side `top_n`.
- **Cohere-style `/v1/rerank`** (what this app does NOT speak): `POST /v1/rerank` with
  `{"model", "query", "documents", "top_n"}`, returns `{"results": [{"index", "relevance_score"}]}`.

If an app only offers a "Cohere rerank" connector, it will not talk to TEI directly without an adapter.
Prefer apps (or connectors) that speak TEI-native `/rerank`, or a generic HTTP node where you control
the request shape. The table below says which is which.

Auth for every route except `/health` is `Authorization: Bearer YOUR_KEY`.

## Quick reference

| App | Consumes a reranker? | How | Dialect |
|-----|----------------------|-----|---------|
| **n8n** | yes | HTTP Request node to `/rerank` | TEI-native (you build the body) |
| **Dify** | yes | "Text Embedding Inference" model provider, add a Rerank model | TEI-native |
| **agentgateway** | as a router | expose `/rerank` as an HTTP/MCP backend; it does not rerank itself | passthrough |
| **Open WebUI** | not externally | its RAG reranker is a local model, not an external API (current versions) | n/a |
| **LibreChat** | not natively | no external rerank hook; use n8n or a custom call | n/a |
| **TEI (embeddings)**, **Qdrant**, **Docling** | no | upstream pipeline stages (retrieve), not consumers | n/a |
| **Langfuse** | observes | trace the rerank calls from the client side | n/a |
| **Ollama**, **rustfs/MinIO** | no | LLM / object storage, unrelated to reranking | n/a |

## n8n (the simplest concrete consumer)

An **HTTP Request** node:

- Method: `POST`
- URL: `https://reranker.example.com/rerank`
- Authentication: Generic -> Header Auth -> Name `Authorization`, Value `Bearer YOUR_KEY`
- Body (JSON):
  ```json
  { "query": "{{ $json.query }}", "texts": {{ JSON.stringify($json.candidates) }} }
  ```
- The response is `[{ "index", "score" }]` sorted best-first. Map each `index` back to your candidate
  array, then keep the top N (slice in a Function node; there is no server-side `top_n`).

A typical flow: retrieve candidates (Qdrant search, or a keyword search), rerank with this node, keep
the top few, pass them to an LLM (Ollama) node.

## Dify (native rerank model provider)

Dify has a **Text Embedding Inference (TEI)** model provider that supports both embedding and rerank
models, and Dify speaks TEI-native `/rerank`.

1. Settings -> Model Provider -> Text Embedding Inference -> Add model.
2. Model type: **Rerank**. Model name: `BAAI/bge-reranker-v2-m3`. Server URL:
   `https://reranker.example.com`. API key: `YOUR_KEY`.
3. In a Knowledge base's retrieval settings (or a workflow's Knowledge Retrieval node), enable
   **Rerank Model** and select it.

Do not use Dify's "Cohere" rerank provider for this app; that expects the Cohere `/v1/rerank` shape,
which TEI does not serve.

## agentgateway (router, not a consumer)

agentgateway fronts LLM and MCP traffic; it does not rerank. If you want one gated front door, you can
add an HTTP route that forwards to `https://reranker.example.com/rerank` (or expose it as an MCP tool),
injecting the Bearer key at the gateway so downstream callers do not hold it. Reranking logic still
lives in whatever app orchestrates retrieve -> rerank -> generate.

## Open WebUI and LibreChat

Current Open WebUI runs its RAG reranker as a local sentence-transformers model, not an external API,
so this app is not a drop-in reranker for it. LibreChat has no external rerank hook. For both, do the
reranking in an orchestration layer (n8n, Dify, or your own code) that calls `/rerank` and feeds the
reranked context in.

## The pipeline neighbours

This reranker is the second stage. The first stage and the generator are separate apps:

```
Docling (parse) -> TEI embeddings -> Qdrant (store + search)  ==>  shortlist
shortlist + query -> BGE Reranker (/rerank) -> top results -> Ollama (answer)
```

Qdrant, the TEI embeddings app, and Docling do not call the reranker; the app that orchestrates the
pipeline does.

## Networking and the proxy timeout

Cross-app calls on the same box go through each app's external `https://` domain and the platform
reverse proxy, which **cuts a request at about 60 seconds** and is not per-app tunable. Reranking a
large batch of long passages on CPU can approach that. Mitigations:

- Keep batches modest. Reranking a shortlist of, say, 20 to 50 passages of a few hundred tokens each is
  well under the limit. Split very large candidate sets into several calls.
- The default `max_batch_tokens` (4096) caps a single request's work; raising it for long passages also
  raises latency, so watch the 60-second ceiling.
- The `localhost`/`127.0.0.1:8080` bypass applies only to code running **inside the reranker's own
  container**, not to other apps. Other apps must use the external domain.

## Verifying an integration

```bash
curl -s https://reranker.example.com/rerank \
  -H "Authorization: Bearer YOUR_KEY" -H 'content-type: application/json' \
  -d '{"query":"what is panda?","texts":["hi","The giant panda is a bear endemic to China."]}'
# -> [{"index":1,"score":0.95...},{"index":0,"score":0.0003...}]   panda outranks hi
```
