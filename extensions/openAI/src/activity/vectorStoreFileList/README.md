# List Vector Store Files Activity

## Overview

The List Vector Store Files activity enables you to retrieve files stored within OpenAI vector stores. This activity provides comprehensive file listing capabilities with support for filtering by processing status, pagination, sorting, and detailed file metadata inspection. It's essential for monitoring vector store content, tracking file processing status, and managing large collections of documents.

This activity uses the OpenAI Vector Store Files API endpoint: `https://api.openai.com/v1/vector_stores/{vector_store_id}/files`

## Prerequisites

- Valid OpenAI API key with vector store access permissions
- An existing OpenAI vector store
- Flogo Enterprise application

## Settings

The List Vector Store Files activity requires the following connection settings:

| Setting | Type | Required | Description |
|---------|------|----------|-------------|
| **API Endpoint URL** | String | Yes | The base URL for the OpenAI API. Typically `https://api.openai.com/v1`. Supports app properties. |
| **OpenAI API Key** | String | Yes | Your OpenAI API authentication key required for vector store operations. Supports app properties for secure storage. |

### Configuration Example
```
API Endpoint URL: https://api.openai.com/v1
OpenAI API Key: sk-your-openai-api-key-here
```

## Input

The List Vector Store Files activity accepts the following input parameters:

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| **vectorStoreID** | String | Yes | - | The unique identifier of the OpenAI vector store to list files from |
| **limit** | Integer | No | 20 | Maximum number of files to return per page (1-100) |
| **filter** | String | No | - | Filter files by processing status. Valid values: "in_progress", "completed", "failed", "cancelled" |
| **order** | String | No | "desc" | Sort order for results. Valid values: "asc" (ascending), "desc" (descending) |
| **after** | String | No | - | Cursor for forward pagination. Use the file ID to retrieve files after this point |
| **before** | String | No | - | Cursor for backward pagination. Use the file ID to retrieve files before this point |
| **timeoutSeconds** | Integer | No | 30 | Request timeout duration in seconds |

### Input Guidelines

- **vectorStoreID**: Must be a valid vector store ID from your OpenAI account (format: `vs_xxxxxxxxxxxxxx`)
- **limit**: Controls page size for pagination; higher values may impact performance
- **filter**: Only valid status values are accepted; invalid values are ignored with a warning
- **order**: Determines chronological ordering of results by creation time
- **after/before**: Use for pagination; provide file IDs from previous responses
- **timeoutSeconds**: Adjust based on expected response time and network conditions

## Output

The activity returns detailed information about vector store files.

| Output | Type | Description |
|--------|------|-------------|
| **files** | Array | Array of vector store file objects with comprehensive metadata |

The full JSON Schema for this output is defined in [`schemas/openai-filelist-response-schema.json`](schemas/openai-filelist-response-schema.json) and is also embedded as the `value` of the `files` output in [`activity.json`](activity.json).

### `files` Array Schema

The `files` output is a top-level JSON array (`type: "array"`) where each element is a vector store file object with the following fields:

| Field | Type | Required | Constraints | Description |
|-------|------|----------|-------------|-------------|
| `id` | string | Yes | Pattern `^file-[a-zA-Z0-9]+$` | Unique OpenAI file identifier (e.g. `file-7Ksr2QJdoEmtKhHb6JDYjd`) |
| `created_at` | integer | Yes | `minimum: 0` | Unix timestamp (seconds) when the file was created |
| `last_error` | object | Yes | See [`last_error`](#last_error-object) | Information about the last error encountered; fields are empty strings when no error occurred |
| `object` | string | Yes | Enum: `"vector_store.file"` | Object type identifier; always the literal `"vector_store.file"` |
| `status` | string | Yes | Enum: `in_progress`, `completed`, `failed`, `cancelled` | Current processing status of the file |
| `usage_bytes` | integer | Yes | `minimum: 0` | Number of bytes the file consumes in the vector store |
| `vector_store_id` | string | Yes | Pattern `^vs_[a-zA-Z0-9]+$` | ID of the parent vector store |
| `attributes` | object | Yes | Free-form key/value map (string, number, boolean, or null values) | Custom metadata associated with the file; may be empty (`{}`) |
| `chunking_strategy` | object | Yes | See [`chunking_strategy`](#chunking_strategy-object) | Strategy used for chunking the file |

#### `last_error` object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `code` | string | Yes | Error code; empty string when no error |
| `message` | string | Yes | Human-readable error message; empty string when no error |

#### `chunking_strategy` object

| Field | Type | Required | Constraints | Description |
|-------|------|----------|-------------|-------------|
| `type` | string | Yes | Enum: `static`, `auto` | Type of chunking strategy applied to the file |
| `static` | object | No | Required when `type == "static"`. See below | Static chunking configuration |

`static` sub-object:

| Field | Type | Required | Constraints | Description |
|-------|------|----------|-------------|-------------|
| `chunk_overlap_tokens` | integer | Yes | `minimum: 0` | Number of tokens to overlap between chunks |
| `max_chunk_size_tokens` | integer | Yes | `minimum: 0` | Maximum size of each chunk in tokens |

### Example Output

```json
[
  {
    "id": "file-7Ksr2QJdoEmtKhHb6JDYjd",
    "created_at": 1777623630,
    "last_error": { "code": "", "message": "" },
    "object": "vector_store.file",
    "status": "completed",
    "usage_bytes": 39619,
    "vector_store_id": "vs_69f461edba448191a6542cb71c1a7a20",
    "attributes": {},
    "chunking_strategy": {
      "type": "static",
      "static": {
        "chunk_overlap_tokens": 400,
        "max_chunk_size_tokens": 800
      }
    }
  }
]
```

### File Status Values

| Status | Description |
|--------|-------------|
| `in_progress` | File currently being processed and chunked |
| `completed` | File successfully processed and available for search |
| `failed` | File processing encountered an error |
| `cancelled` | File processing was cancelled |

## Pagination

The activity automatically handles pagination and retrieves all available files across multiple pages. For manual pagination control:

1. **Forward Pagination**: Use the `after` parameter with the ID of the last file from the previous response
2. **Backward Pagination**: Use the `before` parameter with the ID of the first file from the previous response
3. **Limit Control**: Set `limit` to control the number of files per API request

### Pagination Example

```
First Request:
- limit: 10
- after: (empty)

Response includes files with IDs: file-001, file-002, ..., file-010

Next Request:
- limit: 10
- after: "file-010"

Response includes files with IDs: file-011, file-012, ..., file-020
```

## Usage Examples

### List All Files

Retrieve all files from a vector store:

```
Inputs:
- vectorStoreID: "vs-abc123def456"
- limit: 50
- filter: (empty)
- order: "desc"
- timeoutSeconds: 60
```

### Filter by Processing Status

List only successfully processed files:

```
Inputs:
- vectorStoreID: "vs-abc123def456"
- limit: 20
- filter: "completed"
- order: "desc"
- timeoutSeconds: 30
```

### Monitor Processing Failures

Check for files that failed processing:

```
Inputs:
- vectorStoreID: "vs-abc123def456"
- limit: 100
- filter: "failed"
- order: "asc"
- timeoutSeconds: 45
```

### Large-Scale Inventory

Retrieve comprehensive file inventory with pagination:

```
Inputs:
- vectorStoreID: "vs-abc123def456"
- limit: 100
- filter: (empty)
- order: "desc"
- after: (empty - for first page)
- timeoutSeconds: 120
```

### Check Processing Status

Monitor files currently being processed:

```
Inputs:
- vectorStoreID: "vs-abc123def456"
- limit: 50
- filter: "processing"
- order: "desc"
- timeoutSeconds: 30
```

## Error Handling

The activity provides comprehensive error handling for various scenarios:

### Authentication Errors
- **Invalid API Key**: Authentication failed due to incorrect or expired API key
- **Permission Denied**: API key lacks vector store access permissions

### Validation Errors
- **Missing Vector Store ID**: Required vectorStoreID parameter not provided
- **Invalid Vector Store ID**: Non-existent or inaccessible vector store
- **Invalid Filter Value**: Unsupported filter status (warnings logged, filter ignored)

### Network and Timeout Errors
- **Request Timeout**: API call exceeded configured timeout duration
- **API Rate Limits**: Automatic retry handling with exponential backoff
- **Connection Issues**: Network connectivity problems

### Pagination Errors
- **Invalid Cursor**: Malformed `after` or `before` cursor values
- **Cursor Mismatch**: Pagination cursors from different vector stores

## Best Practices

### Performance Optimization
1. **Appropriate Limits**: Use reasonable `limit` values (20-50) to balance performance and memory usage
2. **Targeted Filtering**: Use status filters to reduce unnecessary data transfer
3. **Timeout Configuration**: Set timeouts based on expected vector store size and network conditions

### Monitoring and Management
1. **Regular Health Checks**: Periodically check for failed files requiring attention
2. **Processing Monitoring**: Monitor files in "processing" status for stuck operations
3. **Storage Management**: Track `usage_bytes` to monitor storage consumption

### Security Considerations
1. **API Key Protection**: Always use app properties for secure API key storage
2. **Access Control**: Implement proper authentication and authorization
3. **Data Privacy**: Be mindful of sensitive metadata in file attributes

### Integration Patterns
1. **Batch Processing**: Process files in batches using pagination
2. **Status Polling**: Regularly check processing status for uploaded files
3. **Error Recovery**: Implement retry logic for failed file operations
4. **Metadata Extraction**: Use custom attributes for enhanced file organization

## Related OpenAI API Documentation

- [Vector Store Files API](https://platform.openai.com/docs/api-reference/vector-stores/files)
- [Vector Stores Overview](https://platform.openai.com/docs/api-reference/vector-stores)
- [File Search](https://platform.openai.com/docs/assistants/tools/file-search)
- [File Management](https://platform.openai.com/docs/api-reference/files)

## Version Information

- **Activity Version**: 1.0.0
- **Supported OpenAI API Version**: v1
- **Flogo Category**: openAI
- **Retry Support**: Enabled with automatic exponential backoff