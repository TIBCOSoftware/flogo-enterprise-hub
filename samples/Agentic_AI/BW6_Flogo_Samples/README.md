# TIBCO BusinessWorks 6 + Flogo — "Better Together" Samples

Agentic AI samples that combine **TIBCO BusinessWorks 6 (BW6)** and **TIBCO Flogo®**: BW6 apps provide the domain microservices and expose them as REST/MCP tools, and a Flogo app does the AI orchestration (LLM planning, tool calls and answer generation).

These samples are **not** built with the `agentic-ai-use-case-builder` skill (the Flogo Design CLI can't build BW6 apps) and they don't follow the governed three-app pattern used in [`Industry_Use_Cases/`](../Industry_Use_Cases/).

## Prerequisites

The prerequisites differ from the rest of `samples/Agentic_AI`. In addition to **TIBCO Flogo® 2.26.7+** (VS Code extension) and an LLM API key, you need:

- **TIBCO BusinessWorks 6** runtime and **TIBCO Business Studio** (6.12.0 HF3 or later, with the palettes the sample lists)
- Any extra infrastructure listed in the sample's README (e.g. Java, Docker, Node.js)

## Samples

| Sample | Industry | What it shows |
|---|---|---|
| [Retail — BW & Flogo, Better Together](./Retail_AI_BW_Flogo/) | Retail & Consumer Goods | BW6 apps expose retail domain APIs through a BW6 MCP Server; a Flogo **REST** orchestrator (`POST /api/query`, port 18085) uses one LLM Client activity to plan, call the BW6 MCP tools (port 18000) and answer. |
