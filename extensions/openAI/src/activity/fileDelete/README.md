# File Delete Activity

This Flogo activity deletes a file from the OpenAI file store using the Files API.

## Overview

The File Delete activity removes a file identified by its id from the OpenAI
file store. Note that deleting a file from the file store does not automatically
remove its association from any vector stores it was added to; use the vector
store file delete API for that.

## Configuration

### Settings

| Setting | Type | Required | Description |
|---------|------|----------|-------------|
| `endPointURL` | string | Yes | Endpoint URL for the OpenAI API (e.g., https://api.openai.com/v1) |
| `apiKey` | string | Yes | OpenAI API key for authentication |

### Inputs

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `fileId` | string | Yes | - | The id of the file to delete (e.g., `file-abc123`) |
| `timeoutSeconds` | integer | No | 30 | Request timeout in seconds |

### Outputs

| Output | Type | Description |
|--------|------|-------------|
| `id` | string | Id of the deleted file |
| `object` | string | Object type, typically `file` |
| `deleted` | boolean | `true` if the file was successfully deleted |

## Usage Examples

### Basic Usage
```json
{
  "fileId": "file-abc123"
}
```

### With Custom Timeout
```json
{
  "fileId": "file-abc123",
  "timeoutSeconds": 60
}
```

## Error Handling

The activity handles the following error conditions:

- **Validation errors**: missing `fileId` or required settings
- **Authentication errors**: invalid API key
- **Network errors**: connection issues
- **API errors**: file not found, rate limiting, etc.
- **Timeout errors**: configurable timeout for long-running requests

## API Reference

This activity uses the OpenAI Files API:
- **Endpoint**: `DELETE /files/{file_id}`
- **Documentation**: https://developers.openai.com/api/reference/resources/files/methods/delete
- **Go SDK**: https://pkg.go.dev/github.com/openai/openai-go/v3#FileService.Delete

## Dependencies

- OpenAI Go client library v3
- Flogo Core framework
