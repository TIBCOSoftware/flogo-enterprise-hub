# Agentic AI — Industry Use-Case Demos (governed)

End-to-end, **industry-specific Agentic AI demos** built on **TIBCO Flogo® Enterprise** — each a complete, PostgreSQL-backed chat assistant that applies the same reusable, **governed three-app pattern** to a different industry. Identity, scope, prices and every state change are decided in SQL, not in prompts, and each demo was tested end to end (including prompt injection).

> ### ▶ How to run these samples
>
> The one-time build toolchain and the exact commands to **build, start and connect to the three apps** — identical for every use case — are in **[How to run these samples → RUNNING_THE_SAMPLES.md](RUNNING_THE_SAMPLES.md)**. A one-command helper, [`setup.py`](setup.py), lives in this folder too. Each use case's own README links back to the run guide from its "Start the apps" step.
>
> Part of the broader TIBCO Flogo Agentic AI collection — see the parent catalogue: **[../README.md](../README.md)**.

## The Three-App Pattern

Every governed use case ships the same **trio** of Flogo apps plus a PostgreSQL database. The design rule is *agentic in the middle, deterministic at the edges*: the AI handles the conversation and the fuzzy reasoning, PostgreSQL decides identity, scope, prices and every state change, and people decide the exceptions. Understand it once and every use case reads the same way:

| App | Role | Trigger | Talks to |
|---|---|---|---|
| **`*MCPServer.flogo`** | The **governed gateway** to the data. **Verified identity:** the caller signs in once and gets a short-lived session token. **Scoped reads:** every tool resolves the caller from that token and SQL decides what they can see — another customer's record is simply "not found". **Guarded two-step writes:** a change is first proposed, then confirmed after an explicit yes, and the database re-checks every rule before applying it. **Human-review routing:** refunds, waivers, appeals and other discretionary requests become routed cases for the right team. | HTTP (streamable MCP) | PostgreSQL · SMTP |
| **`*Agents.flogo`** | One or more **A2A reasoning agents** for the fuzzy step (explain a bill, decode a reason code, rank rebooking or delivery options). They are **read-only** and get only the **minimized input** they need — they never see the customer's identity and cannot change anything. | A2A server (one port per agent) | LLM |
| **`*AIOrchestrator.flogo`** | The **conversation**: understands the request, calls the MCP tools and the A2A agents, asks for a yes before each change, and keeps **per-connection memory** — each browser connection is its own conversation. | WebSocket (`wsserver`) | LLM · MCP · A2A |

```
   Browser Chatbot ──ws──▶ AI Orchestrator ──▶ LLM (OpenAI / Gemini / Anthropic)
                                 │  ├──▶ MCP Server ──▶ PostgreSQL   (identity · scoped reads · guarded writes · cases)
                                 │  └──▶ A2A Agents ──▶ LLM          (read-only reasoning on minimized input)
```

## Use-Case Catalog

Click a use case to open its folder and full README, which lists its ports, database and demo logins.

### Industry use cases (governed — start here)

Grouped by **Industry → Sub-category**, mirroring the [folders in this directory](./). Every one passes the decision framework (agent vs. deterministic vs. human-owned), enforces its rules in SQL, and was tested end to end, including prompt injection.

#### Financial Services → Banking

| Use Case | What it does |
|---|---|
| [Banking — Retail Banking Assistant](./Financial_Services/Banking/Retail_Banking_Assistant_Use_Case/) | Verified customers of fictional Kestrel Bank check balances, transactions, cards & loans, get an agent to decode an unrecognized charge into the real merchant, and dispute it (provisional credit computed in SQL) or block a card in two confirmed steps. Payments to saved payees get scam protection: an agent reads the customer's story for scam signs and SQL bands it (warn, or hold the payment for the fraud team); a third agent turns a hardship story into a brief for Financial Support. Fee refunds, hardship deferrals and held payments go to staff reviewers, who decide them in the same chatbot. |
| [Banking — Corporate Payments Investigation Assistant](./Financial_Services/Banking/Corporate_Payments_Investigation_Use_Case/) | Verified corporate treasury, AP and AR users of fictional Aurelia Global Bank check payment status, rail, FX & fees, get an agent to decode cryptic return/reason codes, and raise a trace or request a recall in two confirmed steps. An agent matches a buyer's short-pay note to invoices and deduction reasons (SQL computes the earned discount and the disputed amount); another compares a new payee's typed name with the name on file, and SQL holds the payment on a mismatch. Recalls, held payments, disputed deductions and fee waivers go to staff reviewers, who decide them in the same chatbot. |

#### Telecommunications → Mobile, Fixed & Cable Operators

| Use Case | What it does |
|---|---|
| [Telecom — Mobile Billing & Spend Control Assistant](./Telecommunications/Mobile_Fixed_Cable_Operators/Telecom_Mobile_Billing_Use_Case/) | Verified customers of fictional US carrier Tidewell Mobile hear why their bill jumped, usually pay-per-use roaming abroad or a premium content subscription (bill-to-bill deltas computed in SQL, narrated by an agent). An agent classifies charges they don't recognize and another recommends a plan from their real usage and travel. Customers then cancel a subscription, add TravelPass, set a roaming limit or change plan in two confirmed steps and email the confirmation; past-due balances and device installment lock-in are enforced in SQL. Refunds/disputes, port-out and suspected fraud go to staff reviewers, who decide them in the same chatbot. |

#### Energy & Utilities → Electric, Gas & Utilities Grid

| Use Case | What it does |
|---|---|
| [Utilities — Electric Outage & Billing Assistant](./Energy_Utilities/Electric_Gas_Utilities_Grid/Electric_Utility_Outage_Billing_Use_Case/) | Verified residential customers of fictional Texas utility Ridgeline Power & Light hear why their bill went up (bill-to-bill deltas, weather and estimated reads computed in SQL, narrated by an agent), report outages (an agent triages hazards; SQL links the report to a known area outage instead of opening a duplicate), pick a rate plan from SQL cost estimates on their real usage, and book a smart-meter upgrade or a reconnect (blocked in SQL while a past-due balance remains). Estimated-read disputes, payment arrangements, medical-baseline protection and hazards go to people, who decide them in the same chatbot. |

#### Energy & Utilities → Oil & Gas

| Use Case | What it does |
|---|---|
| [Energy & Utilities — Oilfield Asset Health Monitoring Assistant](./Energy_Utilities/Oil_Gas/Oilfield_Asset_Health_Monitoring_Use_Case/) | Verified control-room operators of fictional Mesa Ridge Energy watch the health of their region's rod pumps, compressors and wellhead valves, classified deterministically in SQL (threshold table, worst sensor wins). An agent triages a technician's free-text field note (failure mode, parts, safety language — reconciled with the sensors in SQL, safety routed to HSE), another matches past failures and a third drafts the shift handover. Work orders are raised in two confirmed steps (rules enforced in SQL); estimates above $25,000, shut-ins, threshold changes and alert closures go to Production Engineering and safety signals to HSE, who decide them in the same chatbot. |

#### Healthcare & Life Sciences → Providers & Health Systems

| Use Case | What it does |
|---|---|
| [Healthcare — Hospital Post-Discharge Care Assistant](./Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case/) | Verified discharge coordinators of fictional Bellmont Regional Medical Center run each patient's post-discharge checklist for their own ward: an agent ranks clinic slots and the follow-up is booked in two confirmed steps (specialty, window and open slot enforced in SQL); discharge medicines are ordered only from the discharge list and a bed goes to housekeeping only once its patient has left; agents write plain-language instructions and flag home-medicine conflicts for the pharmacist. High-alert medicines, early bed turnovers, prescription changes and discharge decisions go to pharmacists, the charge nurse and the attending, who decide them in the same chatbot. |

#### Transportation & Logistics → Airlines & Aviation

| Use Case | What it does |
|---|---|
| [Airline — Passenger Services Assistant](./Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case/) | Verified travelers of fictional carrier Meridian check flight status & connection risk (computed in SQL), get agent-ranked rebooking options and rebook in two confirmed steps. An agent turns a delayed, lost or damaged bag description into a claim (type, bag and color codes, missing fields — validated and recorded in SQL), and another turns free-text needs into IATA assistance codes (WCHR / WCHS / WCHC …) added to the traveler's own flight as pending. Compensation, interim baggage expenses, assistance confirmation, complaints and name changes go to staff reviewers, who decide them in the same chatbot. |

#### Transportation & Logistics → Parcel & Postal Logistics

| Use Case | What it does |
|---|---|
| [Logistics — Parcel Delivery Assistant](./Transportation_Logistics/Parcel_Postal_Logistics/Parcel_Delivery_Last_Mile_Use_Case/) | Verified recipients of fictional last-mile carrier Swiftbound track parcels, hear what a cryptic delivery exception means (decoded in SQL), get agent-ranked delivery options and reschedule or redirect in two confirmed steps. An agent structures free-text access notes into delivery instructions (SQL checks the safe place, blocks risky instructions and never stores the access code); another classifies damage, missing-contents or lost claims, capped in SQL at the declared value and coverage limit. Signature-required / high-value parcels can't be left unattended. Claims go to staff reviewers, who decide them in the same chatbot. |

#### High Tech & Software → Semiconductors & Electronics

| Use Case | What it does |
|---|---|
| [High Tech — Semiconductor Orders & RMA Assistant](./High_Tech_Software/Semiconductors_Electronics/Semiconductor_Orders_RMA_Use_Case/) | Verified buyers at the US customers of fictional distributor Arcwell Components look up parts, prices, stock, lead times and change notices: an agent matches a pasted BOM line to catalog parts; orders are priced from the price-break table and placed in two confirmed steps (MOQ, stock, credit and the end-of-life last-time-buy date enforced in SQL); an agent classifies a failure story for a two-step RMA and another explains what a change notice means for open orders. RMA dispositions, special pricing, credit changes, factory expedites and large last-time-buys go to quality, sales & pricing and credit reviewers, who decide them in the same chatbot. |

#### Insurance → Property & Casualty / Multi-Line

| Use Case | What it does |
|---|---|
| [Insurance — Auto Policy & Claims Assistant (RAG)](./Insurance/PC_Multi_Line/Auto_Insurance_Policy_Claims_RAG_Use_Case/) | Verified policyholders of fictional Copperleaf Auto Insurance check their policy, coverages, claims and payments (from PostgreSQL) and ask what the policy wording says (RAG over four policy PDFs through the `extensions/openAI` vector search). They file claims in two confirmed steps: agents structure the accident story, read the retrieved wording for exclusions and score the narrative; SQL adds its own signal points, bands the score and routes the claim to normal handling, an adjuster, or Special Investigations with the payment held. Adjusters and investigators decide cases in the same chatbot. |

#### Insurance → Life, Pensions & Wealth

| Use Case | What it does |
|---|---|
| [Insurance — Life & Retirement Member Services Assistant](./Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case/) | Verified members of fictional Harborline Life & Retirement check policies, beneficiaries, 401(k)/IRA balances, holdings and claims. They raise their 401(k) deferral and switch funds in two confirmed steps (plan maximum, IRS limit and holdings enforced in SQL), and file Critical Illness / Income Protection claims after an agent turns their story into a claim type and document list; other agents build a life-event checklist and write the examiner's appeal brief. Beneficiary changes, claim decisions, appeals, withdrawals/rollovers and advice go to people, who decide them in the same chatbot. |

#### Media & Travel → Media & Publishing

| Use Case | What it does |
|---|---|
| [Publishing — Author Services Assistant](./Media_Travel/Media_Publishing/Scholarly_Publishing_Author_Services_Use_Case/) | Verified authors of a fictional scholarly publisher check manuscript status and APC coverage, get an agent's revision checklist from the reviewer comments and journal suggestions for a declined paper, and transfer a manuscript in two confirmed steps after an agent checks their data, ethics, funding and competing-interest statements against the target journal's policy (SQL blocks an incomplete transfer). Fee waivers, appeals, authorship changes, integrity questions and statement exceptions go to staff reviewers, who decide them in the same chatbot. |

#### Aerospace & Defense → Defense & Space

| Use Case | What it does |
|---|---|
| [Aerospace & Defense — MRO AOG Operations Assistant](./Aerospace_Defense/Defense_Space/Aerospace_MRO_AOG_Operations_Use_Case/) | Verified MRO controllers of fictional Northvale Aero Services run aircraft-on-ground recovery for their own base: agents triage a crew write-up to an ATA chapter and likely parts, flag repeat defects and draft the shift handover. Parts are ordered and technicians dispatched in two confirmed steps (part applicability, lead time, certification + type rating and availability enforced in SQL). Spend above the controller's $25,000 limit goes to a maintenance manager, and return-to-service, AD compliance, MEL deferrals and grounding changes to Quality & Airworthiness, who decide them in the same chatbot. |

#### Real Estate → Residential Brokerage

| Use Case | What it does |
|---|---|
| [Real Estate — Lead Engagement Assistant](./Real_Estate/Residential_Brokerage/Real_Estate_Lead_Engagement_Use_Case/) | Verified buyer and seller leads of fictional brokerage Brightpath Realty search listings (filters applied in SQL) and check showings, their agent and market statistics: an agent ranks listings against the buyer's own words; showings are booked in two confirmed steps (slot and double-booking rules enforced in SQL) and move the lead to Active; an agent reads a lead's plans and SQL sets how soon their agent calls; another catches Fair-Housing-sensitive questions so they are answered neutrally. Offers, list-price changes, contract updates and legal or mortgage questions go to sales-agent and compliance reviewers, who decide them in the same chatbot. |

### BW6 + Flogo samples

TIBCO BusinessWorks 6 + Flogo "Better Together" samples are kept under [`BW6_Flogo_Samples/`](../BW6_Flogo_Samples/) — BW6 apps provide the domain APIs / MCP tools and Flogo does the AI orchestration.

| Sample | Industry | Description | Ports | Database | Status |
|---|---|---|---|---|---|
| [Retail — BW & Flogo, Better Together](../BW6_Flogo_Samples/Retail_AI_BW_Flogo/) | Retail & Consumer Goods | Retail assistant where **BW6 apps expose domain REST/MCP** and a Flogo **REST** orchestrator drives the LLM. | Flogo REST `:18085` `/api/query` · BW6 MCP `:18000` | *(inside BW6 apps)* | 🏛️ BW6 |

---

## Feedback

Please contact us at [integration-pm@tibco.com](mailto:integration-pm@tibco.com) with any queries, feedback, or comments.

<!-- SEO Keywords: TIBCO Flogo, Agentic AI, AI Agents, MCP, MCP Server, Model Context Protocol, A2A, Agent-to-Agent, LLM Orchestration, WebSocket, PostgreSQL, RAG, Retrieval Augmented Generation, BusinessWorks, Industry Use Cases, Banking, Insurance, Healthcare, Telecom, Utilities, Aerospace, Manufacturing, Retail, Real Estate, Scholarly Publishing, Logistics, Airline, Governed AI, Agent Governance, Low-Code, integration platform, Enterprise AI, Agentic AI Use Cases, MCP Use Cases, Build MCP Server, Zero-Code MCP Server, No-Code MCP Server, No-Code Agent Builder, Zero-Code Agent Builder, Best Integration Tool, Fastest Integration Tool, Most Performant Integration Tool, High-Performance Integration, Low-Code Integration, No-Code Integration -->

**Topics:** `Agentic AI` · `MCP Server` · `A2A` · `LLM Orchestration` · `Industry Demos` · `Low-Code`

**Hashtags:** #AgenticAI #AgenticAIUseCases #AIAgents #NoCodeAgentBuilder #MCP #MCPServer #ModelContextProtocol #ZeroCodeMCP #BuildMCPServer #LLMOrchestration #EnterpriseIntegration #TIBCOFlogo
