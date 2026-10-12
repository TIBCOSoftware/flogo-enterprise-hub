# Discovery questions: ask the user before you plan

Run this in **Phase 1**, after the build method (Phase 0a) and the environment check (Phase 0), and
before the decision-framework gate. The goal is the most accurate use case for *the user's* domain, not
a plausible one you invented. Every answer below changes a concrete artefact (tables, rules, tools,
seed data, prompts, the demo script), so a wrong guess shows up in front of the audience.

**Migrating a legacy sample** from `Industry_Use_Cases_old/`? Don't run the three rounds. Take the
discovery input from its README.md, database.sql, prompts.md and any `*.spec.md`, play it back, and ask
the single round in [migration-playbook.md](migration-playbook.md).

## Rules

1. **Skip what is already answered.** Read the user's message, any spec file
   ([use-case-spec-template.md](use-case-spec-template.md)) and earlier turns first. Ask only about the
   gaps, and play back what you took from the rest in one line each.
2. **Never fill a gap silently.** If the user says "you decide", decide, and list it under
   **Assumptions** in the plan (Phase 3) so they can still correct it.
3. **Propose, don't interrogate.** Draft domain-specific defaults from what you know of the vertical and
   region (real-sounding products, numbers, rules, teams). Then the user can confirm or edit instead of
   writing from scratch. Mark your recommendation.
4. **Don't ask what you can look up:** DB/LLM/SMTP settings (config.md), free ports, the output folder,
   or whether the catalogue already covers the vertical (`samples/Agentic_AI/README.md`).
5. **Keep a named customer confidential.** If the user names a real prospect or customer, use it only to
   tailor the domain. Never write that name into any file, app, prompt, seed row, transcript, commit
   message or memory. Use a fictional organisation, and say so in the plan.
6. **Three rounds, one message each.** Every round re-reads the whole conversation, so batch the
   questions. Don't drip-feed them. Round 1 is open text. Rounds 2–3 use `AskUserQuestion`: max 4
   questions per call, 2–4 options each, `header` ≤ 12 chars, `multiSelect` for lists. Tailor every
   option to the round-1 answers; the user can always pick "Other". You may put the Phase 0a
   build-method question in the same call as round 2.
7. **Don't volunteer cost, time or token estimates.** Answer them only if the user asks
   ([build-cost-and-time.md](build-cost-and-time.md)).
8. **Default to the USA and USD.** Samples are published for everyone, so propose US locale, USD prices,
   US phone numbers (`+1 xxx 555-01xx`) and US regulations unless the user explicitly asks for another
   country or currency. Naming a prospect from another region is not enough: confirm the locale in round 1.
9. **Lead with the most common real-world scenarios.** Propose the workflows the vertical handles most
   often, the ones a viewer recognises at once, before niche ones. For example: telecom billing → unexpected
   roaming charges, data overage, duplicate or wrong fees, unauthorised premium content, late fees; banking →
   card disputes, failed or duplicate payments, fee reversals; insurance → claim status, coverage questions,
   policy changes. Ask the user to confirm which ones the storyline should use.

## Round 1: context (free text, one numbered message)

Ask these as a short numbered list. End with *"Answer what you can. For anything you'd rather I
draft, say 'you decide' and I'll propose it in the plan."*

| # | Question | Why it matters / what it drives |
|---|---|---|
| 1 | **Industry and segment, and the business problem.** What should this assistant take off people's plates? What does success look like in the demo (e.g. "deflect billing calls", "cut fault-handling time")? | the persona, the operations, the "Why an agent here?" story |
| 2 | **Audience and region.** Who will watch it (execs, architects, operations)? Which country or region (default: USA and USD unless the user explicitly asks otherwise)? Is it tailored for a specific customer or prospect (kept confidential)? | locale, currency, ID formats, regulations (GDPR, POPIA, HIPAA …), local realities that make the demo land (e.g. power outages, local payment methods) |
| 3 | **Who chats.** External customer self-service, an employee agent-assist (a contact-centre rep acting for customers), a partner/dealer, or a field technician? | identity model and scope: a rep can see many customers, a customer only themself |
| 4 | **Domain vocabulary.** Real product, plan or service names, record identifiers, typical prices, limits and SLAs? Or should I invent realistic ones? | seed data, rule thresholds, how authentic the demo feels |
| 5 | **Brand.** A fictional org name, the assistant's name and tone. Or shall I invent them? Any language other than English? | prompts, README, seed data |

## Round 2: who and what (AskUserQuestion, options tailored from round 1)

| # | Question | Typical options (tailor them) | Drives |
|---|---|---|---|
| 6 | **Persona** (only if round 1 left it open) | 2–4 concrete personas for the segment | everything below |
| 7 | **Identity proof** | identifier + one-time code (mobile no. + OTP, account no. + PIN, booking ref + code) | `verify_*` tool, session-token scope |
| 8 | **What the persona looks up** (multiSelect) | 3–4 domain reads (account, bills, orders, status, history …) | scoped-read MCP tools |
| 9 | **What the persona can change** (multiSelect) | 3–4 domain actions. Note which are regrettable (two-step) | guarded-write MCP tools, propose/confirm pairs |

Then, in the same round if there's room or else at the start of round 3:

| # | Question | Typical options | Drives |
|---|---|---|---|
| 10 | **The genuinely fuzzy step(s)** (the A2A reasoning agent: usually one; up to 3 distinct semantic steps, one A2A agent (and port) each — see the Telecom sample `Telecom_Mobile_Billing_Use_Case`) | recommend/rank against free-text needs, classify a free-text description, summarise/explain a document, triage | the A2A agent, its minimised input |
| 11 | **What a person must decide** (multiSelect) | disputes/credits/waivers, identity or fraud-sensitive changes, cancellations/contract breaks, hardship/exceptions, complaints | `open_service_case` request types → teams + SLAs |

If the user can't name a fuzzy step, check the "Why an agent here?" test in
[decision-framework-gate.md](decision-framework-gate.md) before going on. The use case may not need an
agent.

## Round 3: rules, demo and runtime (AskUserQuestion + short free text)

| # | Question | Drives |
|---|---|---|
| 12 | **The rules for each action.** What makes it allowed or blocked (eligibility, limits, prices/fees, time windows, account state)? Propose a default rule set per action with numbers, and ask the user to correct it. | rule functions, reason codes, one seed row per code |
| 13 | **Multi-step requests** to show in one prompt (e.g. "explain my bill, dispute the charge and suggest a cheaper plan") | orchestrator prompt, e2e scenarios |
| 14 | **The demo storyline.** The 3–5-minute happy path, the "wow" moment, and how many demo logins (typically 3: happy path, a blocked case, an exception). | seed personas, `prompts.md`, README demo script |
| 15 | **What the user must never see** (fraud flags, credit scores, internal notes), and **what the assistant must decline** (legal/medical/financial advice, other topics) | which columns stay inside rule functions; out-of-scope wording |
| 16 | **The rule that would hurt most if broken.** This becomes the prompt-injection target. | adversarial e2e turn |
| 17 | **Email confirmation** of executed actions: yes/no (SMTP from config.md) | optional guarded email tool |
| 18 | **Runtime LLM.** Recommend `gpt-5.5` (OpenAI). Alternatives: Azure OpenAI or a gateway (needs a base URL), or a Claude/Gemini-class model. Warn that nano-class models drop tool calls. | the model baked into all three apps |
| 19 | **How far to verify.** Full 4-step ladder (builds binaries locally, spends LLM tokens on a real chat), or stop at step 2 (SQL rules + static validation, no binaries, no LLM) | Phase 5 scope; full ladder = permission to build exes |

Ask about ports, folder or naming only if there's a conflict or the user raised it.

## Fast path

If the user wants to go quickly ("just build it", or a spec that already covers most of this), ask
**one** `AskUserQuestion` round with your proposed defaults for the must-haves: persona (3/6),
actions (9), the fuzzy step (10), the human-owned requests (11) and the runtime model (18). Put
everything else under **Assumptions** in the plan.

## After discovery: the plan opens with a readback

Phase 3 starts with **"What I heard"** (one line per answer, including the fictional org replacing any
named customer) and **"Assumptions"** (every "you decide" and every default the user didn't confirm).
Then come the classification table, tools, agent, rules, demo logins, ports and the test scope. The
user approves or corrects in one reply.
