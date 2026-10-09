# Build cost, time and token use — show ONLY when the user asks

**Do not present this upfront.** Share it only when the user asks about tokens, cost, time, or
how to make a build cheaper/faster. When they do, scale the figures to the actual tool/agent
count and say they are estimates.

Figures come from 5 real builds of the agentic trio (MCP server + A2A agents + orchestrator)
with an Opus-class model, priced at public list prices (5-minute prompt-cache tier). Treat them
as **±50%**. Most "total tokens" are cheap cached reads; the number of back-and-forth turns
drives cost more than app size. Add ~10% if the model is served from a regional Vertex
endpoint. On a Claude subscription seat the build consumes usage quota, not per-token dollars.

## Build (Claude Code)

| Build | Total tokens | Generated (output) | Active time | Wall clock incl. reviews | Cost: Opus 4.8 / Opus 5.5 / Sonnet 5 |
|---|---|---|---|---|---|
| FDA, standard (≈6 tools, 4 agents) | 5–9M | 130–150k | 35–50 min | 50–90 min | $9–12 / $6–8 / $3.5–5 |
| Clone, larger (11 tools, 6 agents) | ~4–5M | ~155k | ~50 min | — | ~$12 / ~$9 / ~$5 |
| + RAG, mid-build scope changes, fix loops | ~13M | ~340k | 80+ min | hours | ~$25 / ~$17 / ~$10 |
| + exe build / local run / deploy | not measured — adds more on top | | | | |

The Opus 5.5 / Sonnet 5 columns reprice the same token volume; a different model takes a
different number of turns, so they are approximations.

## Runtime (the finished apps calling the LLM)

The build model and the runtime model are different things: Claude Code builds the apps; the
apps call the model set in `LLM_Model` (default `gpt-5-nano`). Modelled cost of one full
30-turn `prompts.md` walkthrough:

| Runtime model | 1 walkthrough | 100 walkthroughs |
|---|---|---|
| **gpt-5-nano** (default) | **~$0.04** ($0.03–0.13) | **~$4–10** |
| gpt-5-mini | ~$0.20 | ~$20–50 |
| gpt-5 | ~$1.00 | ~$100–250 |
| gpt-5.5 | ~$3.60 | ~$360–970 |

RAG ingestion (embedding the policy PDFs) is ≈ $0. The orchestrator log prints
`Input Tokens` / `Output Tokens` / `Reasoning Tokens` per turn — use one real run to calibrate.

**Shared conversation memory is the biggest runtime cost driver.** The orchestrator's
`conversationId` is empty, which the connector turns into a constant, so every WebSocket client
shares one history (up to `memoryMaxSize` messages) until the app restarts. Input grows from
~6k to ~160k tokens per turn over a long demo, and two simultaneous users see each other's
context. Restart the orchestrator between demos.

## How to use fewer tokens

**Building (Claude):**
1. Pick a cheaper build model with `/model` (Sonnet 5 ≈ 0.4× Opus 4.8 per token).
2. Put everything in the first prompt (template below) so the build never pauses for questions.
3. Reply within 5 minutes when the build asks something — the prompt cache expires and is
   re-paid on the next turn.
4. One fresh session per build; no side questions in that session.
5. Keep scope small: 3–5 tools, 2–4 agents; skip RAG unless needed; don't change scope mid-build.

**Running (OpenAI):**
1. Keep `gpt-5-nano` (≈90× cheaper than gpt-5.5).
2. Restart the orchestrator between demos (≈74% less input on a 30-turn run).
3. Lower `memoryMaxSize` (100 → 10–20) for up to ~77% less input.

## Lean prompt template

```text
Build an agentic AI use case with FDA (agentic-ai-use-case-builder, FDA-CLI method).
Domain: <industry>. Persona: <who chats>. Identifier: <name + format, e.g. POL-2026-NNNNN>. Locale/currency: <…>.
MCP tools (read-only):
  1. <Name> — <what it returns>
  2. …
A2A agents (write to Postgres):
  1. <Name> — <what it changes>
  2. …
Email agent: yes|no.
Use config.md for LLM / PostgreSQL / SMTP. Target folder: samples/Agentic_AI/<UseCase>_Use_Case/.
No exe build, no local run, no deploy. I'll approve the README in one pass.
```
