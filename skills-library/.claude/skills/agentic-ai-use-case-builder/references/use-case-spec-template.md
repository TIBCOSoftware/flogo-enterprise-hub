# Agentic AI Use Case — Specification Template (spec-driven development)

Copy this file to `<your-use-case>.spec.md`, fill every `<…>` placeholder, delete the guidance
blockquotes, and hand it to the `agentic-ai-use-case-builder` skill. This is the **spec** you provide.

## How this fits spec-driven development (SDD)

SDD separates **WHAT/WHY** (the spec) from **HOW** (the plan + implementation). With this skill the
responsibilities split cleanly — you only author the spec:

| SDD phase (spec-kit) | Who owns it | Where it lives |
|---|---|---|
| **Constitution** — non-negotiable principles/architecture | the **skill** | `SKILL.md` "Key facts" + "Top gotchas" (3-app pattern: MCP = reads, A2A = writes, WebSocket orchestrator; PostgreSQL patterns) |
| **Specify** — requirements, scenarios, acceptance criteria (WHAT/WHY) | **you** | this `*.spec.md` |
| **Clarify** — resolve ambiguity | you + skill | skill Phase 2 asks only about gaps left in the spec |
| **Plan** — architecture/tech (HOW) | the **skill** | skill Phase 3 (maps this spec → 3 Flogo apps, tables, ports, connections) |
| **Tasks / Implement** — generate apps, SQL, docs | the **skill** | skill Phase 4 |
| **Analyze / Validate** — cross-check, run | the **skill** | skill Phase 5 (loads SQL, runs tool/agent SQL, JSON-validates) |

Principles (from the SDD references): write in **domain/ubiquitous language**, describe **intent not
implementation**, be **complete yet concise** (cover the critical path, not every edge case), prefer
**structured, machine-readable** tables and Given/When/Then, and include **interface contracts**
(input → output) — but do **not** name Flogo, MCP, A2A, ports, or SQL here. The skill derives all of
that: read-only lookups → MCP tools, state-changing actions → A2A agents, entities → PostgreSQL,
scenarios/seed-data → `database.sql` + `prompts.md`.

---

# Specification: `<Use Case Name>`

## 1. Intent (WHY)
> One short paragraph: who talks to the system, over what kind of interface (real-time conversational
> chat), the problem being automated, and the business outcome.

`<e.g. A <role> chats in natural language to <do X>; the assistant answers questions and performs
<write actions> on confirmation, replacing <manual process>.>`

## 2. Actors & identification
> Who the end user is, and the **natural identifier** they use to be recognized in chat (mobile
> number, PNR, patient id, account number, …) and its format.

- **Primary actor:** `<role>`
- **Identifier:** `<name>` — format `<pattern, e.g. +62-8XX-XXXX-XXXX / P-2024-NNNNN>`
- **Locale / currency (if money involved):** `<e.g. IDR, en-ID>`

## 3. User scenarios (WHAT — the demoable journeys)
> Use Given/When/Then. Cover: (a) read-only questions, (b) a multi-step action requiring
> confirmation, (c) at least one exception/dispute-style path, (d) an end-to-end flow. These become
> `prompts.md` and the acceptance tests.

- **S1 (read):** Given `<seeded record>`, When the user asks `"<question>"`, Then the assistant `<answers with which facts>`.
- **S2 (action + confirm):** Given `<state>`, When the user asks `"<request>"`, Then the assistant `<validates>`, asks to confirm, and on confirmation `<performs action>` and reports `<result>`.
- **S3 (exception):** Given `<record with a discrepancy>`, When `"<request>"`, Then the assistant detects `<discrepancy>` and `<acts>`.
- **S4 (end-to-end):** `<chain of the above, optionally ending in a notification>`.

## 4. Functional requirements

### 4a. Information lookups (read-only) → the skill maps these to MCP tools
> What facts the user can retrieve. One row per lookup. Keep them as data reads; no side effects.

| Lookup | Input | Returns | Source entity |
|---|---|---|---|
| `<Get… >` | `<identifier / filter>` | `<fields returned>` | `<entity>` |

### 4b. Actions / workflows (state-changing) → the skill maps these to A2A agents
> What the user can *do*. One row per action. Note validation, the state change, and guardrails
> (e.g. confirm first, once-only, idempotency). Include input → output contract.

| Action | Inputs | Validation / steps | Result (output) | Guardrails |
|---|---|---|---|---|
| `<Do… >` | `<params>` | `<checks, cross-reference>` | `<what changes + confirmation>` | `<confirm before write; once-only; etc.>` |

> Optional: a **notification/email** action if the user should be able to request a confirmation
> message. Mark it "invoke once, last."

## 5. Domain entities & data (→ the skill maps these to PostgreSQL tables)
> The nouns behind the lookups/actions, their key fields, relationships, and which is the master
> record keyed by the identifier in §2. Don't write DDL — describe.

| Entity | Key fields | Notes / relationships | Read / written by |
|---|---|---|---|
| `<entity>` | `<fields>` | `<FK to …>` | `<lookups/actions>` |

## 6. Seed-data scenarios (acceptance data)
> The specific demo records that make each scenario in §3 fire. For every action include at least one
> **happy-path** record and one **exception** record the action operates on. State counts.

- `<PersonaA (identifier)>` — `<attributes>` → exercises `<S1/S4>`.
- `<PersonaB (identifier)>` — `<the exception, e.g. charge with no matching usage>` → exercises `<S3>`.
- Target volume: `~<N>` primary records with a realistic spread.

## 7. Acceptance criteria (Validate)
> Observable pass/fail statements tying scenarios to outcomes. The skill verifies data-layer ones by
> running the real queries; behavioral ones are checked in a live run.

- [ ] `<Given … When … Then a row appears in <entity> with <values> / the reply states <fact>.>`
- [ ] Every lookup returns the seeded record for its persona.
- [ ] Each action writes exactly the expected row(s) and is confirmed before writing.

## 8. Out of scope
> What the assistant must politely decline (keeps the orchestrator focused).

- `<e.g. diagnosis/treatment advice, billing disputes, emergencies, SIM swaps, …>`

## 9. Non-functional & constraints
- **Conversation:** real-time streaming chat; multi-turn memory within a session.
- **Privacy/guardrails:** `<e.g. redact identifiers like P-2024-XXXXX; no PHI in logs; confirm before writes>`.
- **Tone:** `<e.g. warm, professional, healthcare-appropriate>`.
- **Termination:** each action bounded (max 3 attempts), report partial results on failure.
- **Security posture (target):** TLS on endpoints, bearer-token auth, rate limiting, on-prem/data-residency LLM (note as future if demo-only).
- **Reuse:** OpenAI / PostgreSQL / SMTP connection settings reused from an existing use case; only the database name changes.

## 10. Assumptions & open questions (Clarify)
> Anything underspecified for the skill to confirm before building.

- `<assumption>` / `<question>`

---

### Handoff
Give the filled spec to the skill: *"Build the `<Use Case Name>` agentic AI use case from
`<path>/<use-case>.spec.md`."* The skill will frame it back, ask only about remaining gaps (§10),
present a plan, then generate the MCP server, A2A agents, orchestrator, `database.sql`,
`reset_data.sql`, `prompts.md`, and `README`, and verify them.
