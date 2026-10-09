# Decision-framework gate: classify every operation before you build it

Run this gate in Phase 1, before anything is designed. Each operation the use case needs goes through two
questions. The answer decides **who owns it**. It is not a choice of style.

```
                 ┌──────────────────────────────────────────────┐
  operation ───► │ Q1  Does it need human judgment, accountability │── yes ──► HUMAN-OWNED
                 │     or discretion (money given away, a decision │           open_review_case → routed team
                 │     reversed, ethics, legal, identity changes)? │           the AI drafts a neutral brief, never decides
                 └──────────────────────────────────────────────┘
                                  │ no
                                  ▼
                 ┌──────────────────────────────────────────────┐
                 │ Q2  Does it need semantic reasoning, ambiguity │── yes ──► AGENT
                 │     resolution, ranking or multi-step planning │           LLM reasons; inputs minimised; read-only
                 │     over unstructured input?                    │           or its writes go through a guarded tool
                 └──────────────────────────────────────────────┘
                                  │ no
                                  ▼
                            DETERMINISTIC
                            SQL rule function / trigger — the LLM only calls it
```

**Positioning line:** *agentic in the middle, deterministic at the edges.* The conversation and the
genuinely fuzzy step are agentic. Identity, eligibility, prices, state changes and routing are
deterministic. Anything a person must answer for is human-owned.

## Classification table (fill in; it goes into the spec and the README)

| Operation | Q1 human? | Q2 semantic? | Owner | Implemented as |
|---|---|---|---|---|
| Verify who the user is | no | no | Deterministic | `verify_*` tool → session token (SQL) |
| Look up the user's own records | no | no | Deterministic | scoped read `FROM my_x(token)` |
| Price / eligibility / limits | no | no | Deterministic | rule function; LLM quotes it verbatim |
| State change the user asked for | no | no | Deterministic, **two-step** | `propose_*` → user yes → `confirm_*` |
| Match free text to a catalogue, rank options, explain | no | **yes** | Agent | A2A agent, gets topic data only |
| Waivers, appeals, exceptions, integrity, identity changes | **yes** | – | Human | `open_review_case` → routed by table |

## Red flags that mean the gate was skipped

- A prompt says "only show the user their own …", "calculate the fee", "check whether they are eligible"
  → that is a Q2 = no operation living in a prompt. Move it to SQL. (`validate_governed_apps.py` G3.)
- An A2A agent **writes** to the database from its own tool flow with LLM-chosen arguments → give the
  write to a guarded MCP tool, or keep the agent read-only.
- The assistant "approves", "waives", "grants", "reverses" anything → that is a Q1 = yes. Open a case.
- An agent receives the user's name, email or identifiers it does not need for its reasoning → minimise.
- A demo has no human-owned path at all → most real domains have one. Find it; it is the credibility beat.

## "Why an agent here?" (mandatory README section)

Every governed sample's README carries this section, written from the table above:

```markdown
## Why an agent here?

| Part | Owner | Why |
|---|---|---|
| <the fuzzy step> | **Agent** | <what makes it semantic: free text vs. catalogue, trade-offs, ambiguity> |
| <identity/rules/prices/state> | **Deterministic (SQL)** | <exact rule; a model must not be able to talk its way past it> |
| <exceptions> | **Human** | <who is accountable, and why an AI must not decide> |

If you removed the LLM, <deterministic parts> would still work through a form. What you would lose is
<the semantic step>. That is the part the agent is for.
```

That last paragraph is the test. If you cannot write it, the use case does not need an agent. Say so
to the user rather than building one.
