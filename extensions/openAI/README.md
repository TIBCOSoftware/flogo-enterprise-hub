# TIBCO Flogo® Connector for OpenAI

A library of **TIBCO Flogo® activities** for the **OpenAI platform**. Drop these activities into any Flogo flow to manage files on OpenAI, build and query **vector stores** for semantic search / RAG, and **generate images** from text — all visually, with no boilerplate code. Built on the official [OpenAI Go client library](https://github.com/openai/openai-go) (v3).

---

## What you can build

- **Retrieval-Augmented Generation (RAG) / knowledge search** — upload documents, index them in a vector store, then run natural-language semantic search to ground an LLM's answers in your own content.
- **Document / file management on OpenAI** — upload, list, and delete files used by assistants, fine-tuning, batch, and vector stores.
- **Vector store lifecycle management** — create, list, inspect, and delete vector stores and monitor file-processing status.
- **Image generation** — turn text prompts into images using OpenAI's GPT-image models.

---

## Activities

All activities appear under the **openAI** category in the Flogo activity palette. Click an activity name for its full reference (settings, inputs, outputs, and examples).

### 📁 File management

| Activity | Purpose | Key inputs | Key outputs |
|---|---|---|---|
| **[File Upload](./src/activity/fileUpload/README.md)** | Upload a local file to OpenAI storage — and, optionally, chunk it and attach it to a vector store in the same step | `filename` or `fileId`, `vectorStoreID`, `fileAttributes` | `id`, `filename`, `bytes`, `purpose` |
| **[File List](./src/activity/fileList/)** | List files already uploaded to OpenAI, filtered by purpose, with pagination | `purpose`, `limit`, `order`, `after` | `files[]` |
| **[File Delete](./src/activity/fileDelete/README.md)** | Delete a file from OpenAI storage by its ID | `fileId` | `id`, `deleted` |

### 🗂️ Vector store management

| Activity | Purpose | Key inputs | Key outputs |
|---|---|---|---|
| **[Create Vector Store](./src/activity/vectorStoreCreate/README.md)** | Create a vector store for semantic search / RAG — optionally attach files, metadata, a chunking strategy, and an expiry policy | `name`, `fileIds`, `metadata`, `expiresAfterDays` | `id` (`vs_…`), `status`, file counts |
| **[List Vector Stores](./src/activity/vectorStoreList/README.md)** | List the vector stores in your account, with ordering and pagination | `limit`, `order`, `after` / `before` | `vectorStores[]`, `hasMore` |
| **[Vector Store File List](./src/activity/vectorStoreFileList/README.md)** | List the files inside a specific vector store and track their processing status | `vectorStoreID`, `filter` (status), `limit` | `files[]` (status, `usage_bytes`, chunking) |
| **[Delete Vector Store](./src/activity/vectorStoreDelete/README.md)** | Delete a vector store by its ID (the underlying files in file storage are kept) | `vectorStoreId` | `id`, `deleted` |

### 🔎 Semantic search

| Activity | Purpose | Key inputs | Key outputs |
|---|---|---|---|
| **[Vector Search](./src/activity/vectorSearch/README.md)** | Run a natural-language semantic search over a vector store and return the most relevant document chunks, ranked by score | `vectorStoreID`, `searchString`, `maxNumberOfResults`, `scoreThreshold`, `rewriteQuery`, `ranker` | `searchResultRows[]` (content, filename, `score`) |

### 🎨 Image generation

| Activity | Purpose | Key inputs | Key outputs |
|---|---|---|---|
| **[Image Create](./src/activity/imageCreate/README.md)** | Generate one or more images from a text prompt using OpenAI GPT-image models | `prompt` (plus model / size / quality / format settings) | `data[]` (`b64_json` or `url`), `usage` |

---

## Common configuration

Every activity shares the same two required connection settings:

| Setting | Description |
|---|---|
| **API Endpoint URL** | Base URL of the OpenAI (or OpenAI-compatible) API — for example `https://api.openai.com/v1`. Supports app properties. |
| **OpenAI API Key** | Key used to authenticate with the API. Store it as an app property / secret rather than hardcoding it. Supports app properties. |

In addition, every activity supports **automatic retry** with exponential backoff, and most accept a per-request **`timeoutSeconds`** input.

> **Tip:** Because the endpoint URL is configurable, these activities can also target OpenAI-compatible platforms (for example a local **Ollama** server at `http://localhost:11434/v1`). Validated embedding models include OpenAI `text-embedding-3-small` / `text-embedding-3-large` and several Ollama models (`nomic-embed-text`, `mxbai-embed-large`, `bge-m3`, and others).

---

## How the activities fit together — a RAG pipeline

A typical retrieval flow chains the activities like this (this is exactly what the [end-to-end sample](./samples/e2e/README.md) does):

1. **Create Vector Store** — create an empty store to hold your indexed content.
2. **File Upload** *(Upload new file and associate to VectorStore)* — upload a document and attach it to the store; OpenAI chunks and embeds it automatically.
3. **Vector Store File List** — confirm the file's `status` is `completed` before searching.
4. **Vector Search** — run natural-language queries and use the returned chunks (with scores) to ground an LLM response.
5. **File Delete** / **Delete Vector Store** — clean up resources when you no longer need them.

For image generation, the flow is a single step: map your text into **Image Create**'s `prompt` and read the generated image(s) from `data[]`.

---

## Getting started

### Prerequisites

- **TIBCO Flogo® Enterprise** with the **Flogo VS Code extension** installed.
- An **OpenAI API key** with access to the Files, Vector Stores, and (for images) Image APIs.
- **Go** toolchain (as required by your Flogo distribution) for building the app.

### Use the activities in a flow

1. **Register this extension** with the Flogo VS Code extension via the **`Flogo › Extensions: Local`** setting, pointing to the absolute path of this `extensions/openAI` folder. (Full step-by-step instructions, including installing the extension and running an app, are in the [end-to-end sample guide](./samples/e2e/README.md).)
2. Open or create a `.flogo` app and add an activity from the **openAI** category to your flow.
3. Set **API Endpoint URL** and **OpenAI API Key** — ideally as app properties so the key stays out of the flow definition.
4. Map the activity's inputs (see each activity's linked README for details).
5. **Configure and Run** the app from VS Code, supplying the API key as an environment variable (e.g. `FLOGO_APP_PROPS_ENV=auto,OPENAI_API_KEY=sk-...`).

### Try the end-to-end sample

The [`samples/e2e`](./samples/e2e/) folder contains a ready-to-run flow (`openai-vector-e2e.flogo`) that creates a vector store, uploads and indexes a file, lists it, searches it, and cleans everything up in a single run. See its [setup & run guide](./samples/e2e/README.md).

---

## Reference

### Image models

`gpt-image-1` (default) · `gpt-image-1-mini` · `gpt-image-1.5` · `gpt-image-2`

> OpenAI deprecated the `dall-e-2` and `dall-e-3` models on **May 12, 2026**. The Image Create activity no longer accepts them — use a `gpt-image-*` model instead.

### Default endpoints

| Platform | Default endpoint URL |
|---|---|
| OpenAI | `https://api.openai.com/v1` |
| Ollama (OpenAI-compatible) | `http://localhost:11434/v1` |

### Useful links

- [OpenAI API reference](https://platform.openai.com/docs/api-reference/introduction)
- [OpenAI Go SDK](https://github.com/openai/openai-go)

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

---

<!-- SEO Keywords: TIBCO Flogo, OpenAI, OpenAI Connector, OpenAI API, Flogo Activities, Vector Store, Vector Search, Semantic Search, RAG, Retrieval Augmented Generation, Embeddings, File Search, Image Generation, gpt-image, Low-Code, No-Code, iPaaS, Enterprise Integration, GoLang -->

**Topics:** `OpenAI` · `Vector Store` · `Semantic Search` · `RAG` · `Image Generation` · `Low-Code`
