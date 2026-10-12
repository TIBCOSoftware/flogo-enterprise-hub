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
apps call the model set in `LLM_Model`. Governed builds need a capable tool-calling model (`gpt-5.5` or
equivalent); nano-class models drop tool calls. Modelled cost of one full
30-turn `prompts.md` walkthrough:

| Runtime model | 1 walkthrough | 100 walkthroughs |
|---|---|---|
| gpt-5-nano (too weak for governed builds) | ~$0.04 ($0.03–0.13) | ~$4–10 |
| gpt-5-mini | ~$0.20 | ~$20–50 |
| gpt-5 | ~$1.00 | ~$100–250 |
| **gpt-5.5** (recommended) | **~$3.60** | **~$360–970** |

RAG ingestion (embedding the policy PDFs) is ≈ $0. The orchestrator log prints
`Input Tokens` / `Output Tokens` / `Reasoning Tokens` per turn — use one real run to calibrate.

**Conversation memory is the biggest runtime cost driver.** Governed builds map `conversationId`
from `Sec-Websocket-Key`, so each connection has its own history (up to `memoryMaxSize` messages).
A long single conversation still grows input from ~6k to ~160k tokens per turn, so reconnect between
demos.

## How to use fewer tokens

**Building (Claude):**
1. Pick a cheaper build model with `/model` (Sonnet 5 ≈ 0.4× Opus 4.8 per token).
2. Answer the discovery questions in the first prompt (template below) so the build needs fewer
   round-trips.
3. Reply within 5 minutes when the build asks something — the prompt cache expires and is
   re-paid on the next turn.
4. One fresh session per build; no side questions in that session.
5. Keep scope small: 3–5 tools, 2–4 agents; skip RAG unless needed; don't change scope mid-build.

**Running (OpenAI):**
1. Use a cheaper model for rehearsals only after checking it still delegates to the A2A agent
   (gpt-5-nano is ≈90× cheaper than gpt-5.5 but drops tool calls).
2. Reconnect between demos (≈74% less input on a 30-turn run).
3. Lower `memoryMaxSize` (100 → 10–20) for up to ~77% less input.

## Which dev model for which phase

Switch with `/model`, or run a step as a subagent with a model override.

| Phase | Model | Why |
|---|---|---|
| Discover + decision-framework gate + spec + plan (1–3) | **Opus** | judgment/architecture: the classification is the whole game |
| Write drivers + SQL, write tests (4) | **Sonnet** | structured codegen following the templates |
| Debug a hard failure (e.g. a SQL planner surprise) | **Opus** | deep reasoning |
| Run the ladder, read logs, triage | **Sonnet** | mechanical; escalate to Opus only when stuck |
| README, prompts.md, catalogue rows, secret scrub | **Haiku** (or Sonnet) | pure mechanical text |

A clean, fresh session is the single biggest saving (often 6–10×): every turn re-reads the whole
accumulated context, so a build chained onto a long prior task costs far more.

## Lean prompt template

```text
Use the agentic-ai-use-case-builder skill (FDA-CLI method) to build a use case.
Business problem / audience / region: <…>
Persona and identity: <who chats; identifier + one-time code>
Reads: <what they look up>
Actions and their rules: <what they can change; limits, prices, what blocks it>
The one fuzzy step (A2A reasoning agent): <…>
Human-owned requests: <what a person must decide, and which team>
Demo storyline: <happy path + "wow" moment>
Email: yes|no.   Runtime model: gpt-5.5.
Verification: stop at step 2 | full ladder.   I'll approve the plan in one pass.
```
