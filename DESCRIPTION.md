## BGE Reranker (bge-reranker-v2-m3) on Text Embeddings Inference

A private, self-hosted **reranking API**. It serves the Apache-2.0 model
[`BAAI/bge-reranker-v2-m3`](https://huggingface.co/BAAI/bge-reranker-v2-m3) - a multilingual
XLM-RoBERTa cross-encoder - using Hugging Face
[Text Embeddings Inference (TEI)](https://github.com/huggingface/text-embeddings-inference), the
production-grade Rust server. The model weights are **baked into the image**, so the app is ready
within seconds of install, runs fully offline, and never phones home.

This is the reranking half of a two-stage retrieve-then-rerank pipeline. A retriever (vector search or
keyword search) returns a shortlist of candidate passages; the reranker scores each candidate against
the query with a cross-encoder, which is far more accurate than the first-stage similarity. You keep
the top results. It pairs naturally with an embeddings server and a vector database.

### The API

Send a query and a list of candidate texts; get a relevance score for each.

```bash
curl https://your-app-domain/rerank \
  -H "Authorization: Bearer $RERANKER_API_KEY" \
  -H 'content-type: application/json' \
  -d '{"query":"what is panda?","texts":["hi","The giant panda is a bear endemic to China."]}'
# -> [{"index":1,"score":0.99...}, {"index":0,"score":0.00...}]   (sorted best-first)
```

Request fields: `query` (string), `texts` (array of strings), and the optional `raw_scores`,
`return_text`, `truncate`, `truncation_direction`. TEI returns a score for every text and sorts the
results best-first; take as many as you need from the top. (TEI's `/rerank` has no server-side `top_n`;
slice client-side.)

### Security and topology

- One strong API key is generated on first run and stored inside the app; send it as
  `Authorization: Bearer <key>`. The reranking API is open at the network layer and protected by the
  key, so programmatic clients get a clean 401 (never an SSO redirect).
- The browsable Swagger docs at `/docs` are placed behind Cloudron single sign-on.
- `/health` is open and unauthenticated for platform monitoring.

### Notes

- CPU inference, amd64 only (the TEI CPU build bundles Intel MKL; there is no arm64 CPU image).
- The model is fixed (baked). For text embeddings, run the companion TEI embeddings app instead.
- This is an API, not a web page. Visiting the domain in a browser lands on the docs, not a dashboard.
