# Vector Store Create Activity

This Flogo activity creates a new vector store in OpenAI using the Vector Stores API.

## Overview

The Vector Store Create activity creates a new vector store that can be used by the
`file_search` tool. Optionally, you can attach existing files, configure a chunking
strategy, set an expiration policy and attach metadata at creation time.

## Configuration

### Settings

| Setting       | Type   | Required | Description                                                                 |
|---------------|--------|----------|-----------------------------------------------------------------------------|
| `endPointURL` | string | Yes      | Endpoint URL for the OpenAI API (e.g., `https://api.openai.com/v1`)         |
| `apiKey`      | string | Yes      | OpenAI API key for authentication                                           |

### Inputs

| Input                | Type    | Required | Default | Description                                                                                          |
|----------------------|---------|----------|---------|------------------------------------------------------------------------------------------------------|
| `name`               | string  | No       | -       | Name of the vector store                                                                             |
| `description`        | string  | No       | -       | Description of the vector store                                                                      |
| `fileIds`            | array   | No       | -       | List of OpenAI file IDs to attach to the new vector store                                            |
| `metadata`           | array   | No       | -       | Array of `{ "key": "...", "value": "..." }` entries (up to 16) attached as metadata on the store     |
| `expiresAfterDays`   | integer | No       | -       | When set, configures an expiration policy of `last_active_at + N days`                               |
| `maxChunkSizeTokens` | integer | No       | -       | Static chunking strategy: maximum chunk size in tokens (only used when `fileIds` is non-empty)       |
| `chunkOverlapTokens` | integer | No       | -       | Static chunking strategy: chunk overlap in tokens (only used when `fileIds` is non-empty)            |
| `timeoutSeconds`     | integer | No       | 60      | Request timeout in seconds                                                                           |

### Outputs

| Output                  | Type    | Description                                                |
|-------------------------|---------|------------------------------------------------------------|
| `id`                    | string  | Vector store ID (e.g., `vs_abc123`)                        |
| `object`                | string  | Object type, always `vector_store`                         |
| `name`                  | string  | Name of the vector store                                   |
| `status`                | string  | `expired`, `in_progress` or `completed`                    |
| `createdAt`             | integer | Unix timestamp when the vector store was created           |
| `lastActiveAt`          | integer | Unix timestamp of the last activity on the vector store    |
| `expiresAt`             | integer | Unix timestamp when the vector store expires (0 if none)   |
| `usageBytes`            | integer | Total bytes used by files in the vector store              |
| `fileCountsTotal`       | integer | Total number of files                                      |
| `fileCountsCompleted`   | integer | Number of files successfully processed                     |
| `fileCountsFailed`      | integer | Number of files that failed to process                     |
| `fileCountsInProgress`  | integer | Number of files currently being processed                  |
| `fileCountsCancelled`   | integer | Number of files that were cancelled                        |
| `metadata`              | object  | Key/value metadata attached to the vector store            |

## Usage Examples

### Minimal
```json
{
  "name": "product-docs"
}
```

### With files, metadata and expiration
```json
{
  "name": "product-docs",
  "description": "Documentation indexed for RAG",
  "fileIds": ["file_abc", "file_def"],
  "metadata": [
    { "key": "team", "value": "rag" },
    { "key": "env",  "value": "prod" }
  ],
  "expiresAfterDays": 30,
  "maxChunkSizeTokens": 800,
  "chunkOverlapTokens": 400
}
```

## API Reference

This activity uses the OpenAI Vector Stores API:
- **Endpoint**: `POST /vector_stores`
- **Documentation**: https://developers.openai.com/api/reference/resources/vector_stores/methods/create

## Dependencies

- OpenAI Go client library v3
- Flogo Core framework
