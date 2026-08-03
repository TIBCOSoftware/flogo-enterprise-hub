# BeautyCo — Flogo Enterprise Retail Demo

An enterprise-ready demo showcasing TIBCO Flogo as the integration backbone for an AI-powered retail platform. Built for live customer demonstrations.

> **Branding:** All assets use "BeautyCo" / "GlowRewards" as placeholders. Swap to the actual customer name in PostgreSQL seed data and app property values before the demo — no code changes required.


![Demo GIF](beauty-intelligence-agent/retailco-demo.gif)

---

## Demo — Beauty Intelligence Agent

**Folder:** [`beauty-intelligence-agent/`](beauty-intelligence-agent/)  
**Pattern:** Agentic AI — Claude calls Flogo MCP tools  
**Port:** MCP 8036 · Mock API 8091  
**Database:** `beauty_db`

### Concept

Flogo acts as the **MCP tool server** exposing the retailer's enterprise data as 12 AI-callable tools. Claude autonomously calls these tools to generate hyper-personalized beauty consultations, loyalty offers, and next-best-actions. All data stays on-prem behind the firewall.

### Demo Story

> *"A Diamond member walks into store 0847. In under 3 seconds, Claude has called 6 Flogo tools, pulled 3 years of purchase history, identified her skin concerns, checked live inventory, created a targeted loyalty offer, queued a replenishment email, and written the consultation back to your database — all without a single line of custom code."*

### The 12 MCP Tools

| Tool | Connector | Returns |
|---|---|---|
| `GetMemberProfile` | PostgreSQL | Name, tier, preferred store, KYC |
| `GetPurchaseHistory` | PostgreSQL | Last 20 transactions by SKU/brand/category |
| `GetLoyaltyAccount` | PostgreSQL | Points balance, tier progress, next expiry |
| `GetBeautyProfile` | PostgreSQL | Skin tone/concerns, hair texture, allergy flags |
| `GetActiveCampaigns` | REST mock | Active promos eligible for this member |
| `GetProductInventory` | REST mock | Stock level + GWP promos per SKU/store |
| `GetStoreContext` | REST mock | Store hours, events, advisor availability |
| `GetRecentReturns` | PostgreSQL | Last 6 months of returns with reasons |
| `UpsertConsultationRecord` | PostgreSQL | Write consultation + recommended SKUs |
| `CreateLoyaltyOffer` | PostgreSQL | Generate targeted offer (BONUS_POINTS/BIRTHDAY/etc.) |
| `TriggerMarketingSequence` | REST mock | Queue post-visit email/push sequence |
| `LogAgentDecision` | PostgreSQL | Audit log with reasoning + confidence score |

### Demo Members (seed data)

| Member ID | Name | Tier | Demo Hook |
|---|---|---|---|
| `M-7724-ASHA` | Asha Patel | DIAMOND | Heavy skincare buyer, 4,200 points |
| `M-1138-CASS` | Cassandra Williams | PLATINUM | Birthday month = today → triggers birthday offer WOW |
| `M-0042-JUNE` | June Chen | MEMBER | New member, paraben allergy flagged — safety check fires |

### Quick Start

```bash
# 1. Create database
psql -U postgres -c "CREATE DATABASE beauty_db;"
psql -U postgres -d beauty_db -f beauty-intelligence-agent/database/beauty-schema.sql
psql -U postgres -d beauty_db -f beauty-intelligence-agent/database/beauty-schema-patch-001.sql
psql -U postgres -d beauty_db -f beauty-intelligence-agent/database/beauty-schema-patch-002.sql

# 2. Start mock API server
cd beauty-intelligence-agent
flogo build -f beauty-mock-apis.flogo -o beauty-mock-apis
./beauty-mock-apis &   # port 8091

# 3. Start MCP server
flogo build -f beauty-intelligence-agent.flogo -o beauty-intelligence-agent
./beauty-intelligence-agent   # port 8036

# 4. Open dashboard (optional)
start beauty-intelligence-agent/dashboard/index.html

# 5. Connect Claude Desktop
# Add to claude_desktop_config.json:
# { "mcpServers": { "beauty-agent": { "url": "http://localhost:8036/mcp" } } }
```

---

**[→ Full README with all details](beauty-intelligence-agent/README.md)**
