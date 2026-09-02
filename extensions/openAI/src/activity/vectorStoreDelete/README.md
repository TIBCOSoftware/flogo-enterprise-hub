# Vector Store Delete Activity

This Flogo activity deletes a vector store from OpenAI using the Vector Stores API.

## Overview

The Vector Store Delete activity removes a vector store identified by its id. The
underlying files are not deleted from the OpenAI files store - only the vector
store and its file associations are removed.

## Configuration

### Settings

| Setting | Type | Required | Description |
|---------|------|----------|-------------|
| `endPointURL` | string | Yes | Endpoint URL for the OpenAI API (e.g., https://api.openai.com/v1) |
| `apiKey` | string | Yes | OpenAI API key for authentication |

### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `vectorStoreId` | string | Yes | - | The id of the vector store to delete (e.g., `vs_abc123`) |
| `timeoutSeconds` | integer | No | 30 | Request timeout in seconds |

### Outputs

| Output | Type | Description |
|--------|------|-------------|
| `id` | string | Id of the deleted vector store |
| `object` | string | Object type, typically `vector_store.deleted` |
| `deleted` | boolean | `true` if the vector store was successfully deleted |

## Usage Examples

### Basic Usage
```json
{
  "vectorStoreId": "vs_abc123"
}
```

### With Custom Timeout
```json
{
  "vectorStoreId": "vs_abc123",
  "timeoutSeconds": 60
}
```

## Error Handling

The activity handles the following error conditions:

- **Validation errors**: missing `vectorStoreId` or required settings
- **Authentication errors**: invalid API key
- **Network errors**: connection issues
- **API errors**: vector store not found, rate limiting, etc.
- **Timeout errors**: configurable timeout for long-running requests

## API Reference

This activity uses the OpenAI Vector Stores API:
- **Endpoint**: `DELETE /vector_stores/{vector_store_id}`
- **Documentation**: https://developers.openai.com/api/reference/resources/vector_stores/methods/delete
- **Go SDK**: https://pkg.go.dev/github.com/openai/openai-go/v3#VectorStoreService.Delete

## Dependencies

- OpenAI Go client library v3
- Flogo Core framework
