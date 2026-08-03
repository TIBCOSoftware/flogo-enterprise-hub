# Upload File Activity

## Overview

The Upload File activity enables you to upload files to OpenAI's file storage system for use with various OpenAI services including assistants, fine-tuning, batch processing, and vector stores. This activity provides comprehensive file management capabilities with support for custom metadata, chunking strategies, and optional vector store integration.

This activity uses the OpenAI Files API endpoint: `https://api.openai.com/v1/files` and, when applicable, the Vector Stores API endpoint: `https://api.openai.com/v1/vector_stores/{vector_store_id}/files`.

## Supported Use Cases

The activity supports three distinct use cases, selected explicitly via the **Operation** setting:

| # | Operation | Required Inputs | Behavior |
|---|-----------|-----------------|----------|
| 1 | **Upload new file** | `filename` | Uploads the local file to OpenAI file storage. The file is **not** associated with any vector store. |
| 2 | **Upload new file and Associate to VectorStore** | `filename` + `vectorStoreID` | Uploads the local file to OpenAI file storage and then attaches it to the specified vector store (with chunking and optional metadata). |
| 3 | **Associate existing file to VectorStore** | `fileId` + `vectorStoreID` | Skips upload and attaches an already-uploaded OpenAI file (identified by `fileId`) to the specified vector store. |

### Input Mapping Requirements

Input mappings are validated against the selected **Operation**. The following inputs must be mapped (non-empty expression in the mapper):

- **Upload new file** → `filename` must be mapped.
- **Upload new file and Associate to VectorStore** → `filename` and `vectorStoreID` must be mapped.
- **Associate existing file to VectorStore** → `fileId` and `vectorStoreID` must be mapped.

A validation error is raised in Flogo Studio when a required input is not mapped for the chosen operation.

## Prerequisites

- Valid OpenAI API key with file upload permissions
- Local file system access to files for upload
- Flogo Enterprise application

## Settings

The Upload File activity requires the following connection and configuration settings:

| Setting | Type | Required | Default | Description |
|---------|------|----------|---------|-------------|
| **Operation** | String | Yes | "Upload new file" | The operation to perform. Selects one of the three supported use cases and drives input mapping validation. |
| **API Endpoint URL** | String | Yes | - | The base URL for the OpenAI API. Typically `https://api.openai.com/v1`. Supports app properties. |
| **OpenAI API Key** | String | Yes | - | Your OpenAI API authentication key required for file operations. Supports app properties for secure storage. |
| **Purpose** | String | Yes | "assistants" | The intended purpose of the uploaded file. Determines how OpenAI processes and uses the file. |
| **Maximum Chunk Size Tokens** | Integer | No | 800 | Maximum number of tokens per chunk when adding to vector store. Range: 100-4096. |
| **Chunk Overlap Tokens** | Integer | No | 400 | Number of tokens that overlap between adjacent chunks for better context preservation. |
| **Timeout in Seconds** | Integer | Yes | 300 | Upload timeout duration in seconds. Increase for large files or slow connections. |

### Operation Options

The **Operation** setting accepts the following values:

| Operation | Description |
|-----------|-------------|
| `Upload new file` | Upload a local file to OpenAI file storage only. |
| `Upload new file and Associate to VectorStore` | Upload a local file and attach it to a vector store. |
| `Associate existing file to VectorStore` | Attach an already-uploaded OpenAI file to a vector store. |

### Purpose Options

The **Purpose** setting accepts the following values:

| Purpose | Description |
|---------|-------------|
| `assistants` | Files for use with OpenAI Assistants API (default) |
| `batch` | Files for batch processing operations |
| `fine-tune` | Training data files for model fine-tuning |
| `vision` | Images for vision model processing |
| `user_data` | User-provided data files |
| `evals` | Evaluation datasets |

### Configuration Example
```
Operation: Upload new file
API Endpoint URL: https://api.openai.com/v1
OpenAI API Key: sk-your-openai-api-key-here
Purpose: assistants
Maximum Chunk Size Tokens: 800
Chunk Overlap Tokens: 400
Timeout in Seconds: 600
```

## Input

The Upload File activity accepts the following input parameters:

| Input | Type | Required | Description |
|-------|------|----------|-------------|
| **filename** | String | Conditional | Full path to the local file to upload. Required when **Operation** is `Upload new file` or `Upload new file and Associate to VectorStore`. Must be accessible from the Flogo runtime environment. |
| **fileId** | String | Conditional | Identifier of an existing OpenAI file. Required when **Operation** is `Associate existing file to VectorStore`. |
| **vectorStoreID** | String | Conditional | Identifier of the OpenAI vector store the file is added to (with chunking). Required when **Operation** is `Upload new file and Associate to VectorStore` or `Associate existing file to VectorStore`. |
| **fileAttributes** | Object | No | Custom metadata key-value pairs to associate with the file when adding to a vector store. Ignored for Use Case 1. |

### Input Guidelines

- **filename**: Must be an absolute or relative path to an existing file. Provide for upload use cases (1 and 2).
- **fileId**: Must reference an existing OpenAI file (for example, `file-abc123`). Provide for Use Case 3.
- **vectorStoreID**: Must reference an existing OpenAI vector store when provided. Required for Use Cases 2 and 3.
- **fileAttributes**: Structure should contain key-value pairs as objects with "key" and "value" properties. Only applied when the file is being associated with a vector store.

### File Attributes Example
```json
{
  "fileAttributes": [
    {
      "key": "department",
      "value": "engineering"
    },
    {
      "key": "document_type",
      "value": "specification"
    },
    {
      "key": "version",
      "value": "2.1"
    }
  ]
}
```

## Output

The activity returns detailed information about the uploaded file.

| Output | Type | Description |
|--------|------|-------------|
| **id** | String | Unique OpenAI file identifier for the uploaded file |
| **object** | String | Object type, typically "file" |
| **bytes** | String | File size in bytes |
| **createdAt** | String | Upload timestamp in Unix epoch format |
| **filename** | String | Original filename as stored in OpenAI |
| **purpose** | String | Confirmed purpose classification for the file |

### Output Example
```json
{
  "id": "file-abc123def456",
  "object": "file",
  "bytes": "245760",
  "createdAt": "1640995200",
  "filename": "user_manual.pdf",
  "purpose": "assistants"
}
```

## Supported File Types

The activity automatically detects MIME types and supports various file formats including:

- **Documents**: PDF, Word, Text files
- **Images**: PNG, JPEG, GIF, WebP
- **Data**: JSON, CSV, JSONL
- **Code**: Various programming language files

File type support may vary depending on the specified **Purpose**.

## Vector Store Integration

Vector store integration is **optional** and only happens when `vectorStoreID` is provided (Use Cases 2 and 3). When enabled, the activity:

1. Uploads the file to OpenAI file storage (Use Case 2) **or** reuses the existing file referenced by `fileId` (Use Case 3)
2. Processes the file content using the configured chunking strategy
3. Adds the processed chunks to the specified vector store
4. Associates custom metadata (`fileAttributes`) with the vector store file entry

When `vectorStoreID` is not provided (Use Case 1), the file is uploaded to OpenAI file storage only and no vector store calls are made.

### Chunking Strategy

The activity uses a static chunking strategy with the following parameters:

- **Max Chunk Size**: Configurable token limit per chunk (100-4096)
- **Chunk Overlap**: Token overlap between chunks for context preservation
- **Custom Metadata**: Applied to all chunks created from the file

## Usage Examples

### Use Case 1 — Upload File Only

Upload a document to OpenAI file storage without attaching it to any vector store. Set **Operation** to `Upload new file` and map `filename`:

```
Settings:
- Operation: "Upload new file"
- Purpose: "assistants"
- Timeout: 300

Inputs:
- filename: "/path/to/user_manual.pdf"
- fileId: (empty)
- vectorStoreID: (empty)
- fileAttributes: (empty)
```

### Use Case 2 — Upload File and Associate with a Vector Store

Upload a document and add it to a vector store with chunking and metadata. Set **Operation** to `Upload new file and Associate to VectorStore` and map `filename` and `vectorStoreID`:

```
Settings:
- Operation: "Upload new file and Associate to VectorStore"
- Purpose: "assistants"
- Max Chunk Size Tokens: 1000
- Chunk Overlap Tokens: 200
- Timeout: 600

Inputs:
- filename: "/documents/knowledge_base.pdf"
- fileId: (empty)
- vectorStoreID: "vs-abc123def456"
- fileAttributes: [
    {"key": "category", "value": "documentation"},
    {"key": "priority", "value": "high"}
  ]
```

### Use Case 3 — Associate an Existing OpenAI File with a Vector Store

Attach a file that has already been uploaded to OpenAI to a vector store. Set **Operation** to `Associate existing file to VectorStore` and map `fileId` and `vectorStoreID`:

```
Settings:
- Operation: "Associate existing file to VectorStore"
- Purpose: "assistants"
- Max Chunk Size Tokens: 1000
- Chunk Overlap Tokens: 200
- Timeout: 300

Inputs:
- filename: (empty)
- fileId: "file-abc123def456"
- vectorStoreID: "vs-abc123def456"
- fileAttributes: [
    {"key": "category", "value": "documentation"}
  ]
```

### Fine-tuning Data Upload

Upload training data for model fine-tuning:

```
Settings:
- Purpose: "fine-tune"
- Vector Store ID: (empty)
- Timeout: 900

Inputs:
- filename: "/training_data/examples.jsonl"
- fileAttributes: (empty)
```

### Batch Processing File

Upload file for batch operations:

```
Settings:
- Purpose: "batch"
- Vector Store ID: (empty)
- Timeout: 1200

Inputs:
- filename: "/batch_jobs/requests.jsonl"
- fileAttributes: (empty)
```

## Error Handling

The activity provides comprehensive error handling for common scenarios:

### Upload Errors
- **File Not Found**: Invalid or inaccessible file path
- **Permission Denied**: Insufficient file system permissions
- **Timeout**: Upload exceeds configured timeout duration
- **API Rate Limits**: Automatic retry with exponential backoff

### Vector Store Errors
- **Invalid Vector Store ID**: Non-existent or inaccessible vector store
- **Chunking Failures**: Issues with content processing or tokenization
- **Metadata Errors**: Invalid custom attribute formatting

### Validation Errors
- **Missing API Key**: Authentication configuration issues
- **Invalid Purpose**: Unsupported file purpose specification
- **File Size Limits**: Files exceeding OpenAI's size restrictions

## Best Practices

### Security
1. **API Key Management**: Always use app properties for secure API key storage
2. **File Path Validation**: Ensure file paths are validated and sanitized
3. **Access Control**: Limit file system access to necessary directories

### Performance
1. **Timeout Configuration**: Set appropriate timeouts based on file sizes and network conditions
2. **Chunking Optimization**: Adjust chunk sizes based on content type and use case
3. **Batch Operations**: Group multiple file uploads when possible

### Vector Store Integration
1. **Metadata Design**: Use consistent and meaningful metadata keys across files
2. **Chunk Overlap**: Configure overlap based on content structure and search requirements
3. **Purpose Alignment**: Ensure file purpose matches intended vector store usage

### File Management
1. **File Organization**: Maintain organized file structures for easier management
2. **Version Control**: Include version information in metadata for document tracking
3. **Cleanup**: Regularly review and manage uploaded files to control storage costs

## Related OpenAI API Documentation

- [Files API](https://platform.openai.com/docs/api-reference/files)
- [Vector Stores API](https://platform.openai.com/docs/api-reference/vector-stores)
- [Assistants File Search](https://platform.openai.com/docs/assistants/tools/file-search)
- [Fine-tuning](https://platform.openai.com/docs/guides/fine-tuning)
- [Batch API](https://platform.openai.com/docs/guides/batch)

## Version Information

- **Activity Version**: 1.0.1
- **Supported OpenAI API Version**: v1
- **Flogo Category**: openAI
- **Retry Support**: Enabled with automatic exponential backoff