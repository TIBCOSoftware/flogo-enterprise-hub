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
| 9810 | 9810 | 9812 | 9813–9815 | `Aerospace_Defense/Defense_Space/Aerospace_MRO_AOG_Operations_Use_Case` (3 agents) | `aerospace_mro_governed` |
| 9820 | 9820 | 9822 | 9823–9825 | `High_Tech_Software/Semiconductors_Electronics/Semiconductor_Orders_RMA_Use_Case` (3 agents) | `semiconductor_governed` |
| 9840 | 9840 | 9842 | 9843–9845 | `Media_Travel/Media_Publishing/Scholarly_Publishing_Author_Services_Use_Case` (3 agents) | `author_services` |
| 9850 | 9850 | 9852 | 9853–9855 | `Transportation_Logistics/Airlines_Aviation/Airline_Passenger_Services_Use_Case` (3 agents) | `airline_governed` |
| 9860 | 9860 | 9862 | 9863–9865 | `Financial_Services/Banking/Retail_Banking_Assistant_Use_Case` (3 agents) | `banking_governed` |
| 9870 | 9870 | 9872 | 9873–9875 | `Financial_Services/Banking/Corporate_Payments_Investigation_Use_Case` (3 agents) | `payments_governed` |
| 9890 | 9890 | 9892 | 9893, 9894, 9896 | `Transportation_Logistics/Parcel_Postal_Logistics/Parcel_Delivery_Last_Mile_Use_Case` (3 agents; 9895 skipped — Feature_Samples `BankAPIGateway` uses it) | `parcel_delivery` |
| 9900 | 9900 | 9902 | 9903–9905 | `Telecommunications/Mobile_Fixed_Cable_Operators/Telecom_Mobile_Billing_Use_Case` (3 agents) | `mobile_billing` |
| 9910 | 9910 | 9912 | 9913–9915 | `Insurance/PC_Multi_Line/Auto_Insurance_Policy_Claims_RAG_Use_Case` (3 agents; 9919 RAG ingestion) | `auto_insurance_governed` |
| 9920 | 9920 | 9922 | 9923–9925 | `Healthcare_Life_Sciences/Providers_Health_Systems/Hospital_Post_Discharge_Care_Use_Case` (3 agents) | `hospital_governed` |
| 9930 | 9930 | 9932 | 9933–9935 | `Insurance/Life_Pensions_Wealth/Life_Pensions_Member_Services_Use_Case` (3 agents) | `life_pensions_governed` |
| 9940 | 9940 | 9942 | 9943–9945 | `Energy_Utilities/Electric_Gas_Utilities_Grid/Electric_Utility_Outage_Billing_Use_Case` (3 agents) | `power_distribution_governed` |
| 9950 | 9950 | 9952 | 9953–9955 | `Energy_Utilities/Oil_Gas/Oilfield_Asset_Health_Monitoring_Use_Case` (3 agents) | `predictive_maintenance_governed` |
| 9960 | 9960 | 9962 | 9963–9965 | `Real_Estate/Residential_Brokerage/Real_Estate_Lead_Engagement_Use_Case` (3 agents) | `realestate_governed` |

## Next free blocks

`9800`, `9830`, `9970`. **Avoid** `9880` (Feature_Samples `Agent-Privilege-IDs`) and `9990`
(Feature_Samples `9998`) while those apps exist.

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
| 9895 | `no-mcp/BankAPIGateway.flogo` (REST) | — (skipped by Parcel Delivery, whose agents use 9893, 9894 and 9896) |
| 9898 | `no-mcp/BankOpsAgentsNoMCP.flogo` agent URL; also `Travel-Itinerary-Planner/TravelItineraryPlannerA2A.flogo` | — |

Other Feature_Samples ports sit outside `98xx`–`99xx` except `9998` (Healthcare-Compliance-Agent and
Smart-Supply-Chain-Assistant WebSockets).

## BW6 + Flogo samples (permanent — avoid)

| Sample | Ports | Status |
|---|---|---|
| `BW6_Flogo_Samples/Retail_AI_BW_Flogo` | 9500, 18000, 18085 | moved to `samples/Agentic_AI/BW6_Flogo_Samples/`; not migrated (the "Better Together" BW6 + Flogo showcase) |

These ports stay taken.
