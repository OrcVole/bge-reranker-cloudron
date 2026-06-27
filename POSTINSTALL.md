### This is a reranking API, not a web page

There is no dashboard to open. The app serves `POST /rerank` over HTTP. Visiting the domain in a
browser lands on the Swagger docs (behind login), not a UI. The model `BAAI/bge-reranker-v2-m3` is
baked into the image, so the app is ready within seconds; there is no first-boot download.

### 1. Get your API key

Open a Terminal for this app (the `>_` button in the dashboard) and run:

```
cat /app/data/.secrets/keys.env
```

Copy the `RERANKER_API_KEY` value. It was generated on first run and never changes on update or
restore, so you can configure integrators with it once.

### 2. Call the reranker

Send it as `Authorization: Bearer <key>`:

```
curl https://__APP_DOMAIN__/rerank \
  -H "Authorization: Bearer YOUR_KEY" \
  -H 'content-type: application/json' \
  -d '{"query":"what is panda?","texts":["hi","The giant panda is a bear endemic to China."]}'
```

You get a relevance score for each text, sorted best-first, with the original index:

```
[{"index":1,"score":0.99...}, {"index":0,"score":0.00...}]
```

Take as many top results as you need (slice client-side; there is no server-side `top_n`).

### 3. Where things are

- `POST /rerank` and `/info`, `/metrics`: protected by the Bearer key.
- `/health`: open, for platform monitoring.
- `/docs`: the interactive Swagger UI, behind Cloudron login. This is the `Open` button target.

### Security

The reranking API is open at the network layer and protected by the key, so a request without the key
returns a clean `401` rather than a login redirect (this is what lets non-browser clients integrate).
Do not put the Cloudron single sign-on wall in front of `/rerank`. Keep the key secret; it is stored
inside the app at `/app/data/.secrets/keys.env` and is never written to the logs.
