# Vector Store List Activity

This Flogo activity lists vector stores from OpenAI using the Vector Stores API.

## Overview

The Vector Store List activity allows you to retrieve a list of vector stores from your OpenAI account. It supports pagination and ordering options to help you efficiently manage and browse through your vector stores.

## Configuration

### Settings

| Setting | Type | Required | Description |
|---------|------|----------|-------------|
| `endPointURL` | string | Yes | Endpoint URL for the OpenAI API (e.g., https://api.openai.com/v1) |
| `apiKey` | string | Yes | OpenAI API key for authentication |

### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `limit` | integer | No | 20 | Number of objects to return (1-100) |
| `order` | string | No | "desc" | Sort order by created_at timestamp ("asc" or "desc") |
| `after` | string | No | - | Cursor for pagination - object ID to start after |
| `before` | string | No | - | Cursor for pagination - object ID to start before |
| `timeoutSeconds` | integer | No | 30 | Request timeout in seconds |

### Outputs

| Output | Type | Description |
|--------|------|-------------|
| `vectorStores` | array | Array of vector store objects |
| `hasMore` | boolean | Indicates if more objects are available for pagination |
| `firstId` | string | ID of the first object in the returned data |
| `lastId` | string | ID of the last object in the returned data |

## Usage Examples

### Basic Usage
List all vector stores with default settings:
```json
{
  "limit": 20,
  "order": "desc"
}
```

### Pagination
To retrieve the next page of results:
```json
{
  "limit": 10,
  "order": "desc",
  "after": "vs_abc123"
}
```

### Custom Ordering
List vector stores in ascending order of creation:
```json
{
  "limit": 50,
  "order": "asc"
}
```

## Vector Store Object Structure

Each vector store object in the `vectorStores` output array contains:

- `id`: Unique identifier for the vector store
- `object`: Object type ("vector_store")
- `created_at`: Creation timestamp
- `name`: Display name of the vector store
- `description`: Optional description
- `bytes`: Total size in bytes
- `file_counts`: Object containing counts of files by status

## Error Handling

The activity handles various error conditions:

- **Authentication errors**: Invalid API key
- **Network errors**: Connection timeouts or network issues
- **API errors**: Rate limiting, quota exceeded, etc.
- **Timeout errors**: Configurable timeout for long-running requests

## API Reference

This activity uses the OpenAI Vector Stores API:
- **Endpoint**: `GET /vector_stores`
- **Documentation**: https://developers.openai.com/api/reference/resources/vector_stores/methods/list

## Dependencies

- OpenAI Go client library v3
- Flogo Core framework