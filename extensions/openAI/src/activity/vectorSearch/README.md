# Vector Search Activity

## Overview

The Vector Search activity enables you to search through OpenAI vector stores to find relevant documents based on semantic similarity. This activity leverages OpenAI's vector search capabilities to perform intelligent document retrieval using natural language queries.

This activity uses the OpenAI Vector Store Search API endpoint: `https://api.openai.com/v1/vector_stores/{vector_store_id}/search`

## Prerequisites

- Valid OpenAI API key with access to vector store operations
- An existing OpenAI vector store populated with documents
- Flogo Enterprise application

## Settings

The Vector Search activity requires the following connection settings:

| Setting | Type | Required | Description |
|---------|------|----------|-------------|
| **API Endpoint URL** | String | Yes | The base URL for the OpenAI API. Typically `https://api.openai.com/v1`. Supports app properties. |
| **OpenAI API Key** | String | Yes | Your OpenAI API authentication key. This is required to authenticate with the OpenAI API. Supports app properties for secure storage. |

### Configuration Example
```
API Endpoint URL: https://api.openai.com/v1
OpenAI API Key: sk-your-openai-api-key-here
```

## Input

The Vector Search activity accepts the following input parameters:

| Input | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| **vectorStoreID** | String | Yes | - | The unique identifier of the OpenAI vector store to search within |
| **searchString** | String | Yes | - | The query text to search for. This will be converted to a vector and used to find similar documents |
| **maxNumberOfResults** | Integer | Yes | - | Maximum number of search results to return. Controls pagination and limits response size |
| **rewriteQuery** | Boolean | No | false | Whether to allow OpenAI to rewrite the query for better search results |
| **scoreThreshold** | Number | No | 0.20 | Minimum similarity score threshold (0.0-1.0). Results below this score will be filtered out |
| **ranker** | String | No | "auto" | Ranking algorithm to use. Options: "auto", "none", or specific ranker types |

### Input Guidelines
- **vectorStoreID**: Must be a valid vector store ID from your OpenAI account
- **searchString**: Use natural language queries for best results
- **maxNumberOfResults**: Consider API rate limits and response size when setting this value
- **scoreThreshold**: Higher values (closer to 1.0) return more precise matches; lower values return more diverse results
- **ranker**: "auto" is recommended for most use cases as it optimizes relevance scoring

## Output

The activity returns search results as an array of vector store search response objects.

| Output | Type | Description |
|--------|------|-------------|
| **searchResultRows** | Array | Array of search result objects containing document content and metadata |

### Search Result Structure

Each result in the `searchResultRows` array contains:

```json
{
  "attributes": {
    "DocGroup": {
      "OfString": "document-group-name",
      "OfFloat": 0,
      "OfBool": false
    },
    "DocType": {
      "OfString": "PDF",
      "OfFloat": 0,
      "OfBool": false
    },
    "DownloadURL": {
      "OfString": "https://example.com/document.pdf",
      "OfFloat": 0,
      "OfBool": false
    }
  },
  "content": [
    {
      "text": "The actual document content chunk",
      "type": "text"
    }
  ],
  "file_id": "file-abc123",
  "filename": "document.pdf",
  "score": 0.85
}
```

### Output Properties

- **attributes**: Metadata associated with the document, stored as union types with OfString, OfFloat, and OfBool fields
- **content**: Array of text chunks from the matching document
- **file_id**: OpenAI file identifier for the source document
- **filename**: Original filename of the document
- **score**: Similarity score indicating relevance (0.0-1.0, higher is more relevant)

## Usage Examples

### Basic Document Search

Search for information about "customer service policies":

```
Inputs:
- vectorStoreID: "vs-abc123def456"
- searchString: "customer service policies"
- maxNumberOfResults: 5
- rewriteQuery: false
- scoreThreshold: 0.3
- ranker: "auto"
```

### High-Precision Search

Search with strict relevance requirements:

```
Inputs:
- vectorStoreID: "vs-abc123def456"
- searchString: "API authentication methods"
- maxNumberOfResults: 3
- rewriteQuery: true
- scoreThreshold: 0.8
- ranker: "auto"
```

### Large Result Set Search

Retrieve comprehensive results for broad queries:

```
Inputs:
- vectorStoreID: "vs-abc123def456"
- searchString: "product documentation"
- maxNumberOfResults: 20
- rewriteQuery: true
- scoreThreshold: 0.1
- ranker: "auto"
```

## Error Handling

The activity includes built-in retry functionality and handles the following error scenarios:

- **Authentication Errors**: Invalid or missing API key
- **Invalid Vector Store**: Non-existent or inaccessible vector store ID
- **API Rate Limits**: Automatic retry with exponential backoff
- **Network Issues**: Connection timeout and retry handling

## Best Practices

1. **API Key Security**: Always use app properties to store your OpenAI API key securely
2. **Query Optimization**: Use natural language queries for better semantic matching
3. **Result Limiting**: Set appropriate `maxNumberOfResults` to balance performance and completeness
4. **Score Thresholding**: Adjust `scoreThreshold` based on your accuracy requirements
5. **Query Rewriting**: Enable `rewriteQuery` for complex or ambiguous search terms
6. **Pagination**: The activity automatically handles pagination to retrieve all results within the specified limit

## Related OpenAI API Documentation

- [Vector Stores API](https://platform.openai.com/docs/api-reference/vector-stores)
- [Vector Store Search](https://platform.openai.com/docs/api-reference/vector-stores/search)
- [File Search](https://platform.openai.com/docs/assistants/tools/file-search)

## Version Information

- **Activity Version**: 1.0.1
- **Supported OpenAI API Version**: v1
- **Flogo Category**: openAI