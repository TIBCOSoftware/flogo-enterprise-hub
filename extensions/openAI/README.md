Flogo OpenAi API Client Extension
==============================

Overview
--------

This framework provides a library of Flogo activities for interacting with the OpenAI API interface. The framework provides the base interaction for Flogo flows with the purpose of demonstration and better understanding of Flogo activities, with a current focus on supporting text generation, image generation, and embeddings creation and storage via the Responses API.


OpenAI Go API Library Version - v3.31.0

Implemtation status
-------

### Completed

| Client Activity                     | Status                        | Open AI Docs |
| ------------------------------------| ------------------------------| ---------------------------------------------------|
| Files API - upload file             | Completed                     | https://developers.openai.com/api/reference/resources/files/methods/create |
| Files API - delete file             | Completed                     | https://developers.openai.com/api/reference/resources/files/methods/delete |
| Files API - list files              | Completed                     | https://developers.openai.com/api/reference/resources/files/methods/list |
| Vector Store API  - Create store    | Completed                     | https://developers.openai.com/api/reference/resources/vector_stores/methods/create |
| Vector Store API  - Delete store    | Completed                     | https://developers.openai.com/api/reference/resources/vector_stores/methods/delete |
| Vector Store API  - List stores     | Completed                     | https://developers.openai.com/api/reference/resources/vector_stores/methods/list |
| Vector Store API - Search           | Completed                     | https://developers.openai.com/api/reference/resources/vector_stores/methods/search |

### In Progress

| Client Activity                     | Status                        | Open AI Docs |
| ------------------------------------| ------------------------------| ---------------------------------------------------|
| ResponsesCreate                        | In Dev (text and Images)    | https://developers.openai.com/api/reference/resources/responses/methods/create
| ImagesCreate                          | In Dev                        | https://developers.openai.com/api/reference/resources/images/methods/generate |
| EmbeddingsCreate                      | In Dev                       | https://developers.openai.com/api/reference/resources/embeddings/methods/create |

### Out of Scope

These activites have are out of scope since they are not relavant for scoped use cases.

| Client Activity                     | Status                        | Open AI Docs |
| ------------------------------------| ------------------------------| ---------------------------------------------------|
| Chat API                            | Out of scope                  ||
| Completions API                     | Out of scope                  ||
| Realtime API                        | Out of scope                  ||
| Assistants API                      | Out of scope                  ||
| Batch API                           | Out of scope                  ||
| Containers API                      | Out of scope                  ||
| Fine Tuning API                     | Out of scope                  ||
| Graders API                         | Out of scope                  ||
| Moderations API                     | Out of scope                  ||

## Use Cases 

These are some of the example use cases we are being reviewed as part of the client extension development.

| Client Activity                     | Status                        |
| ----------------------------------- | ------------------------------|
| Embeddings                          | Testing                       |
| Responses Text Generation           | In Dev                        |
| Create New Image                    | In Dev                        |
| Edit Existing Image                 | In Dev                        |
| Edit Existing Image Multiple        | In Dev                        |
| Edit Existing Image Mask            | In Dev                        |
| Responses - Structured Response     | Backlog                       |
| Responses - Web Search              | Backlog                       |
| Responses - File Search (RAG)       | Backlog                       |
| App with Flogo MCP                  | Backlog                       |     
| Responses - Function Calling        | Out of scope                  |
| Create New Image (mulitple Images)  | Backlog                       |
| Responses - Remote MCP              | Out of scope                  |
| Audio Generation                    | Out of scope                  |
| Deep Research                       | Out of scope                  |  
| Moderation                          | Out of scope                  |

## OpenAI api Go Library

To interact with the open AI API the official go library is used.  More information on the API can be found here:

### SDK Overview
https://github.com/openai/openai-go

### API Docs
https://github.com/openai/openai-go/blob/main/api.md

### Open AI API Overview
https://platform.openai.com/docs/api-reference/introduction


## More Information

For more information please reach out to the repository owner.

## Compatible Embeding Models

|Platform | Model                           | Last Known Test Status |
|---------|---------------------------------|------------------------|
|Open AI  | text-embedding-3-small          | Pass                   | 
|Open AI  | text-embedding-3-large          | Pass                   | 
|Ollama   | nomic-embed-text:latest         | Pass                   | 
|Ollama   | mxbai-embed-large:latest        | Pass                   | 
|Ollama   | bge-m3:latest                   | Pass                   |
|Ollama   | all-minilm:latest               | Pass                   | 
|Ollama   | snowflake-arctic-embed2:latest  | Pass                   |
|Ollama   | bge-large:latest                | Pass                   |
|Ollama   | paraphrase-multilingual:latest  | Pass                   |
|Ollama   | granite-embedding:latest        | Pass                   |
|Ollama   | embeddinggemma:latest           | Pass                   | 

## Default URLs

| Platfrom             | Default Enpoint URL       | Company Website URL   |
|----------------------|---------------------------|---------------------- |
| Open AI.             | https://api.openai.com/v1 | https://platform.openai.com/docs/api-reference/introduction | 
| Ollama               | http://localhost:1143.    | https://olama.com     |
| Amazon Bedrock       |                           | https://aws.amazon.com/bedrock/
| Azure OpenAI         |                           | https://azure.microsoft.com/en-gb/products/ai-foundry/models/openai/ |
| Cloudflar Workers AI |.                          | https://developers.cloudflare.com/workers-ai/|
| Paralon AI           |                           | https://perlonai.com/ |
| Open Router          |                           | https://openrouter.ai |     

## Supported Inference Platforms

| Platfrom       | /v1/completions | /v1/embeddings | /v1/models  | /v1/responses | /v1/images/* | /v1/audio/* | /v1/fine_tuning/* | /v1/assistants |
|----------------|-----------------|----------------|------------|---------------|--------------|-------------|-------------------|----------------|
| Open AI.       | ✅ - NB        | ✅ - NB       | ✅ - NB   | ✅ - In Dev  |  ✅ - NB    | ✅ - NB    | ✅ - NB          | ✅ - NB       |       
| Ollama         | ✅ - NB        | ✅ - NB       | ✅ - NB.  | Partial - FT  |  NS          |  NS         | NS                | NS             |
| Amazon Bedrock | ✅ - NB        | NS             | NS         | ✅ In Dev    | NS Y         |  NS         | NS                | NS             |
| Azure OpenAI   | ✅ - NB        | -              | -          | -             | -            | -           |  -                |  -             |      
| Cloudflare. AI | -               | -              | -          | -             | -            | -           |  -                |  -             |    
| Paralon AI     | -               | -              | -          | -             | -            | -           |  -                |  -             |  
| OpenRouter     | -               | -              | -          | -             | -            | -           |  -                |  -             |  

## Supported Vector Database Platforms

| Platfrom             | POST /v1/files    | POST /v1/vector_stores | POST /v1/vector_stores/{vs_id}/files | vector store search | POST /v1/responses with tools: [{type: "file_search"}] |
| ---------------------| ------------------|------------------------| -------------------------------------| --------------------| -------------------------------------------------------| 
| Open AI.             | ✅           |  ✅             | ✅ -                         | ✅                 | ✅ - NB                                               |  
| Azure AI Search      | -                 | -                      | -                                    | -                   | -                                                      |
| Pinecone             | -                 | -                      | -                                    | -                   | -                                                      |
| Weaviate             | -                 | -                      | -                                    | -                   | -                                                      |
| Qdrant               | -                 | -                      | -                                    | -                   | -                                                      |
| Milvus / Zilliz      | -                 | -                      | -                                    | -                   | -                                                      |
| Chroma               | -                 | -                      | -                                    | -                   | -                                                      |
| Redis (Vector).      | -                 | -                      | -                                    | -                   | -                                                      |
| MongoDB Atlas Vector | -                 | -                      | -                                    | -                   | -                                                      |



## Key to compatibility tables

NS = Platform / OpenAI for Platform does not support this capability
NT = Not Tested.  Not tested, or Testing not complete for this AI platform but capability exists in extension.  
NB = Not Built.  This capability is not currenlty available in the extension but the AI Platform supports it.
NA = Underlying platform does not support this capability. 
FT = Said supported on paper is currently failing testing. 
Partial = Partial capability from platform backend supported. 
- = Unkown till paper execise carried out on platform.

## Ranking Options
These are the ones specifc to Open AI.  There will be a need to add custom values.

Use none when latency matters most
Use default-2024-11-15 when consistency matters most
Use auto when you want OpenAI to manage ranking evolution
