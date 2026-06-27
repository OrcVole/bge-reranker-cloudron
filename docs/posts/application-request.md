<!--
DRAFT application-request / App Wishlist post. Persona: OrcVole. Modeled on the operator's wishlist style.
Anonymity: verified - upstream + github.com/OrcVole public URLs only; no private hosts, emails, or keys.
BLOCKED ON INPUT: confirm the target venue (Cloudron forum App Wishlist vs official inclusion request)
and any venue-specific template before posting.
SCREENSHOTS: attach the Swagger /docs page and the app tile icon.
-->

* **Title**: BGE Reranker on Cloudron - self-hosted cross-encoder reranking API for better RAG

---

* **Main Page**: https://huggingface.co/BAAI/bge-reranker-v2-m3
* **Git**: https://github.com/FlagOpen/FlagEmbedding (model) - served by https://github.com/huggingface/text-embeddings-inference (TEI)
* **Licence**: Apache-2.0 (both the model and the TEI server)
* **Dockerfile**: Yes - official TEI CPU image; this package bakes the model weights into the image
* **Demo**: none (it is an API); the model card has usage examples

---

* **Summary**: `BAAI/bge-reranker-v2-m3` is a multilingual cross-encoder **reranker**. Reranking is the
  second stage of retrieve-then-rerank: a fast first-stage retriever (embeddings plus a vector database,
  or keyword search) returns an approximate shortlist, and the reranker reads the query and each
  candidate passage together to score true relevance, which is far more accurate than first-stage
  similarity. It is the cheapest large quality win for RAG and self-hosted search. Served by Hugging
  Face Text Embeddings Inference, it exposes a simple `POST /rerank` (query + texts -> scores) protected
  by a generated API key.

---

* **Notes**:
  - *Why I like it*: it is the highest-leverage, lowest-effort accuracy improvement you can add to a
    retrieval stack, it is multilingual, and it is genuinely useful on its own. It pairs naturally with
    AI apps people already run on Cloudron - the TEI embeddings package and Qdrant for first-stage
    retrieval, then this for reranking, then an LLM (Ollama) to answer.
  - *Packaging reality*: I have built a working **community package** that bakes the model into the
    image (no first-boot download, fully offline), protects `/rerank` with a first-run Bearer key, puts
    the Swagger docs behind SSO, and survives update and restore:
    **https://github.com/OrcVole/bge-reranker-cloudron**. The interesting work was memory: TEI's default
    warmup OOM-kills a long-context reranker on CPU, so the package caps `max_batch_tokens` and bounds
    the MKL/OpenMP thread pool. It would be a strong candidate for official support.
  - *Concerns*: amd64 only (the TEI CPU build bundles Intel MKL); memory scales with the thread count,
    so size CPU and RAM together; the default caps effective input length for memory safety and is
    tunable for long-context reranking.

---

* **Alternative to**: closed-source Cohere Rerank and Voyage rerank APIs; other open rerankers
  (Jina reranker, mxbai-rerank, the smaller `bge-reranker-base`/`-large`). This model is the
  multilingual, Apache-2.0, TEI-native option.
* **Screenshots**: _attach images - the Swagger /docs page and the app tile icon_
