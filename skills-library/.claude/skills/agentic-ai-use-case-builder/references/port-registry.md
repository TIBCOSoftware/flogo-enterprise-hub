# Port registry: one block of ten ports per governed sample

Every governed sample gets its own block of ten local ports, so any two samples can run side by side on
one laptop and the chatbot URLs in the READMEs never clash. Pick the block in **Phase 0**.

## Convention

| Port | App | Property |
|---|---|---|
| `X0` | `<Prefix>AIOrchestrator` — WebSocket | `WebSocket_PORT` |
| `X1` | unused (spare) | — |
| `X2` | `<Prefix>MCPServer` — MCP (HTTP streamable) | `MCP_SERVER_PORT` |
| `X3`… | `<Prefix>Agents` — **one port per A2A agent** (`X3`, `X4`, `X5` …; at most 3 agents) | `<agent>_PORT` (string) + `<agent>_URL` |
| `X9` | optional extra app (e.g. a RAG ingestion app) | per app |

**Rule:** pick the **next free block** from the tables below, and **update this file in the same change**
that adds the sample (and its README ports table and the catalogue row). Never reuse a block, even one
whose sample was deleted, until this file says it is free. Before claiming a block, confirm nothing else
binds it:

```bash
git grep -nE '\b9[89][0-9]{2}\b' -- 'samples/*.flogo' 'samples/*.md' | grep -iE 'port|url|localhost|ws://' | grep -E '\b<X>[0-9]\b'   # <X> = e.g. 997
```

## Governed samples (verified against each app's properties)

| Block | WS | MCP | A2A | Sample (`samples/Agentic_AI/Industry_Use_Cases/…`) | DB |
|---|---|---|---|---|---|
| 9840 | 9840 | 9842 | 9843 | `Media_Travel/Media_Publishing/Scholarly_Publishing_Author_Services_Use_Case` | `author_services` |
| 9850 | 9850 | 9852 | 9853 | `Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case` | `airline_governed` |
| 9860 | 9860 | 9862 | 9863 | `Financial_Services/Banking/Retail_Banking_Assistant_Use_Case` | `banking_governed` |
| 9870 | 9870 | 9872 | 9873 | `Financial_Services/Banking/Corporate_Payments_Investigation_Use_Case` | `payments_governed` |
| 9890 | 9890 | 9892 | 9893 | `Transportation_Logistics/Parcel_Postal_Logistics/Parcel_Delivery_Last_Mile_Use_Case` | `parcel_delivery` |
| 9900 | 9900 | 9902 | 9903–9905 | `Telecommunications/Mobile_Fixed_Cable_Operators/Telecom_Mobile_Billing_Use_Case` (3 agents) | `mobile_billing` |

## Reserved for the legacy migrations ([migration-playbook.md](migration-playbook.md))

Checked free across the repo (app properties, trigger settings, READMEs) on 2026-10-12.

| Block | WS | MCP | A2A | Extra | Planned sample |
|---|---|---|---|---|---|
| 9810 | 9810 | 9812 | 9813 | | `Aerospace_Defense/Defense_Space/Aerospace_MRO_AOG_Operations_Use_Case` |
| 9820 | 9820 | 9822 | 9823 | | `High_Tech_Software/Semiconductors_Electronics/Semiconductor_Orders_RMA_Use_Case` |
| 9910 | 9910 | 9912 | 9913 | 9919 RAG ingestion | `Insurance/PC_Multi_Line/Auto_Insurance_Policy_Claims_RAG_Use_Case` |
| 9920 | 9920 | 9922 | 9923 | | `Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case` |
| 9930 | 9930 | 9932 | 9933 | | `Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case` |
| 9940 | 9940 | 9942 | 9943 | | `Energy_Utilities/Electric_Gas_Utilities_Grid/Electric_Utility_Outage_Billing_Use_Case` |
| 9950 | 9950 | 9952 | 9953 | | `Energy_Utilities/Oil_Gas/Oilfield_Asset_Health_Monitoring_Use_Case` |
| 9960 | 9960 | 9962 | 9963 | | `Real_Estate/Residential_Brokerage/Real_Estate_Lead_Engagement_Use_Case` |

A sample with more than one agent takes `X4`, `X5` from its own block. When a migration lands, move its
row to the governed table.

## Next free blocks

`9800`, `9830`, `9970`. **Avoid** `9880` (Agent-Privilege-IDs `9880` + legacy Telecom Invoice `9882–9885`),
`9980` (legacy Life & Pensions `9982–9988`) and `9990` (Feature_Samples `9998`, legacy Hospital `9999`)
while those apps exist.

## Known overlaps (documented, re-port later)

`Feature_Samples/Agent-Privilege-IDs` predates this registry and shares ports with two governed blocks.
Don't run it at the same time as those samples:

| Port | Agent-Privilege-IDs app | Clashes with |
|---|---|---|
| 9870 | `BankOpsAgents.flogo` (WebSocket) | Corporate Payments WS |
| 9871 | `BankOpsMCPServer.flogo` (MCP) | — (spare port of the 9870 block) |
| 9872 | `orchestrated/BankOpsSpecialists.flogo` (MCP) | Corporate Payments MCP |
| 9880 | `orchestrated/BankOpsOrchestrator.flogo` (WebSocket) | — (block avoided) |
| 9890 | `no-mcp/BankOpsAgentsNoMCP.flogo` (WebSocket) | Parcel Delivery WS |
| 9895 | `no-mcp/BankAPIGateway.flogo` (REST) | — (spare port of the 9890 block) |
| 9898 | `no-mcp/BankOpsAgentsNoMCP.flogo` agent URL; also `Travel-Itinerary-Planner/TravelItineraryPlannerA2A.flogo` | — |

Other Feature_Samples ports sit outside `98xx`–`99xx` except `9998` (Healthcare-Compliance-Agent and
Smart-Supply-Chain-Assistant WebSockets).

## Legacy ranges to avoid while `Industry_Use_Cases_old/` exists

| Legacy sample | Ports |
|---|---|
| Aerospace_Defense_MRO | WS 8085 · MCP 9095 · A2A 8091–8094 |
| Airline_Passenger_Services | WS 8083 · MCP 9093 · A2A 8074–8076 · POC apps 8054, 9044, 9111, 3005 |
| Auto_Insurance_Assistant_RAG | WS 9700 · MCP 9701 · A2A 9711–9714 · ingestion 9720 |
| Hospital_AI-Agent | WS 8652 · MCP 9092 · A2A 8070–8073 · REST 9095, 9999 |
| Life_And_Pensions | WS 9600 · MCP 9982 · A2A 9983–9988 |
| Logistics_Transport | WS 9690 · MCP 9790 · A2A 9791–9794 |
| Power_Distribution | WS 9680 · MCP 9682 · A2A 9683–9686 |
| Predictive_Maintenance | 8080, 8083, 9093, 9095, 9898 |
| Real_Estate_Lead_Assistant | WS 9590 · MCP 9592 · A2A 9593–9597 |
| Retail_Banking_Assistant | WS 8088 · MCP 9096 · A2A 8710–8712 |
| Semiconductor_Customer | WS 9310 · MCP 9098 · A2A 8730–8735 |
| Telecom_Invoice_Chatbot | WS 9500 · MCP 9882 · A2A 9883–9885 |

None of these falls in a governed or reserved block. Once `_old` is deleted, these ranges are free.

## BW6 + Flogo samples (permanent — avoid)

| Sample | Ports | Status |
|---|---|---|
| `BW6_Flogo_Samples/Retail_AI_BW_Flogo` | 9500, 18000, 18085 | moved to `samples/Agentic_AI/BW6_Flogo_Samples/`; not migrated (the "Better Together" BW6 + Flogo showcase) |

These ports stay taken after `_old` is deleted.
