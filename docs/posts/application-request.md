<!--
Cloudron forum post - App Wishlist template. Persona: OrcVole.
Anonymity: verified - upstream + github.com/OrcVole public URLs only; no private hosts, emails, or keys.
SCREENSHOTS in the repo screenshots/ dir: docs.png (the Swagger /docs page), app-tile.png (the icon in
the dashboard), overview.png (a branded explainer card).
-->

* **Title**: BGE Reranker on Cloudron - self-hosted cross-encoder reranking for better RAG

---

* **Main Page**: https://huggingface.co/BAAI/bge-reranker-v2-m3
* **Git**: https://github.com/FlagOpen/FlagEmbedding (model) - served by https://github.com/huggingface/text-embeddings-inference (TEI)
* **Licence**: Apache-2.0 (both the model and the TEI server)
* **Dockerfile**: Yes - the official TEI CPU image; this package bakes the model weights into the image
* **Demo**: no hosted demo (it is an API); the model card has usage examples, and the package serves a small landing page plus Swagger docs once installed

---

* **Summary**: `BAAI/bge-reranker-v2-m3` is a multilingual cross-encoder **reranker**. Reranking is the second stage of retrieve-then-rerank: a fast first-stage retriever (embeddings plus a vector database, or keyword search) returns an approximate shortlist, and the reranker reads the query and each candidate passage together to score true relevance, which is far more accurate than first-stage similarity. You keep the top few. It is the cheapest large quality win for RAG and self-hosted search. Served by Hugging Face Text Embeddings Inference, it exposes a simple `POST /rerank` (query plus texts, returns a score for each) protected by a generated API key.

---

* **Notes**:
  - *Why I like it*: it is the highest-leverage, lowest-effort accuracy improvement you can add to a retrieval stack, it is multilingual, and it is genuinely useful on its own. It pairs naturally with AI apps people already run on Cloudron - the TEI embeddings package and Qdrant for first-stage retrieval, then this for reranking, then an LLM (Ollama) to answer.
  - *Packaging reality*: I have built a working **community package** that bakes the model into the image (no first-boot download, fully offline), protects `/rerank` with a first-run Bearer key, puts the Swagger docs behind SSO, serves a public landing page at `/`, and survives update and restore (key byte-identical): **https://github.com/OrcVole/bge-reranker-cloudron**. It is verified end to end on Cloudron 9.x, including live calls from n8n and Windmill. It would be a strong candidate for official support, and it completes the existing TEI and Qdrant community stack.
  - *Concerns*: amd64 only (the TEI CPU build bundles Intel MKL); memory scales with the thread count, so size CPU and RAM together (the package caps both and sets a 6 GiB default); TEI binds its port only after a model warmup, so the package fronts it with a small nginx health proxy.

---

* **Alternative to / Libhunt link**: https://www.libhunt.com/r/FlagEmbedding - an open, multilingual, Apache-2.0 alternative to the closed Cohere Rerank and Voyage rerank APIs, and to other open rerankers (Jina reranker, mxbai-rerank, the smaller `bge-reranker-base` and `-large`).
* **Screenshots**: _`screenshots/docs.png` (the Swagger API docs, showing `/rerank`), `screenshots/app-tile.png` (the icon in the dashboard), and `screenshots/overview.png` (a branded explainer card)_
