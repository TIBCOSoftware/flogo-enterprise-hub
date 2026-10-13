#!/usr/bin/env python3
"""Build CorporatePaymentsAIOrchestrator.flogo with fda only (Aurelia Global Bank corporate payments assistant, governed).
WebSocket trigger -> AI Agent (22 MCP tools + three A2A reasoning agents) -> WebSocket write.

  MCP server     CorporatePaymentsMCPServer  http://localhost:9872/corporate-payments-mcp  (app property CorporatePaymentsMCPServer_URL)
  A2A agents     payment_triage_agent        http://localhost:9873  (payment_triage_agent_URL)
                 remittance_match_agent      http://localhost:9874  (remittance_match_agent_URL)
                 payee_name_match_agent      http://localhost:9875  (payee_name_match_agent_URL)

One chatbot, two personas: client users verify with verify_client, Aurelia staff reviewers (Payment Operations, Client
Servicing) with verify_reviewer; the role comes only from the verify tool (SQL checks it on every call).
Per-connection memory: conversationId = the connection's Sec-Websocket-Key, so people never share a conversation (or a
verified session token). Headers schema is INLINE (runtime-gotchas.md section 1). The system prompt lives in
_rebuild/orchestrator_prompt.txt. Rules (scope, eligibility, cash split, name-check bands, routing, authority) live in SQL.

Re-run:  python _rebuild/build_orchestrator.py      (OUT_DIR=<empty dir> to replay; refuses to overwrite)
Secrets: the OpenAI key is read at build time from env LLM_API_KEY or config.md API_Key and never printed."""
import json, os, sys
os.environ.setdefault("LLM_MODEL", "gpt-5.5")      # SPEC section 2: runtime model gpt-5.5 (env still wins)
os.environ.setdefault("PG_DB", "payments_governed")   # unused here (no DB connection) - keeps fda_common happy
from fda_common import App, jtmp

app = App("CorporatePaymentsAIOrchestrator.flogo", os.environ.get("OUT_DIR"))
f = app.fda
WS_PORT, WS_PATH = "9870", "/corporatepayments"
MCP_NAME, MCP_URL = "CorporatePaymentsMCPServer", "http://localhost:9872/corporate-payments-mcp"
AGENTS = [("payment_triage_agent", "http://localhost:9873"),
          ("remittance_match_agent", "http://localhost:9874"),
          ("payee_name_match_agent", "http://localhost:9875")]
FLOW = "Orchestrator_Flow"

SYS = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "orchestrator_prompt.txt"), encoding="utf-8").read().strip()

print("== project + connections ==")
f("cp", "CorporatePaymentsAIOrchestrator",
  "Aurelia Global Bank governed AI Orchestrator - WebSocket chat for verified corporate clients and staff reviewers")
app.llm_connection()
f("cap", "WebSocket_PORT", "number", WS_PORT)
f("cap", f"{MCP_NAME}_URL", "string", MCP_URL)
for name, url in AGENTS:
    f("cap", f"{name}_URL", "string", url)

f("cc", MCP_NAME, "con_mcpserverconfig")
f("sa", "connection", f"{MCP_NAME}.settings.serverType", "http")
f("sa", "connection", f"{MCP_NAME}.settings.serverUrl", f"{MCP_NAME}_URL", "-C", "app-property")
f("sa", "connection", f"{MCP_NAME}.settings.httpTransportType", "streamable")
for name, _ in AGENTS:
    f("cc", f"{name}A2AServer", "con_a2aserverconnection")
    f("sa", "connection", f"{name}A2AServer.settings.serverUrl", f"{name}_URL", "-C", "app-property")

print("== trigger + flow ==")
f("ct", "WebsocketServer", "tr_wsserver", "WebSocket server")
f("sa", "trigger", "WebsocketServer.settings.port", "WebSocket_PORT", "-C", "app-property")
f("cf", FLOW, "Corporate Payments orchestrator flow")
f("ca", FLOW, "AIAgent", "act_agenticai_agentactivity", "AI Agent")
f("ca", FLOW, "WebsocketWriteData", "act_websocket_wswritedata", "Write to websocket")

print("== AI Agent settings ==")
S = f"{FLOW}.AIAgent.settings"
f("sa", "activity", f"{S}.llmProviderConnection", app.conn_ref("OpenAIConn"))
f("sa", "activity", f"{S}.model", "LLM_Model", "-C", "app-property")
f("sa", "activity", f"{S}.temperature", "--jsonValue", "0")            # 0 = omitted -> provider default (gotcha 2)
f("sa", "activity", f"{S}.tokenLimit", "--jsonValue", "8000")
f("sa", "activity", f"{S}.enableGuardrails", "--jsonValue", "true")
f("sa", "activity", f"{S}.rateLimit", "--jsonValue", "30")             # OWASP resource-overload: cap requests/min
f("sa", "activity", f"{S}.redactSensitiveData", "--jsonValue", "false")  # true would mask the client ID / passcode / staff code
f("sa", "activity", f"{S}.responseType", "Text")
f("sa", "activity", f"{S}.conversationStoreType", "Memory")
f("sa", "activity", f"{S}.memoryMaxSize", "--jsonValue", "60")
f("sa", "activity", f"{S}.systemPrompt", SYS)
f("sa", "activity", f"{S}.mcpServers", "--jsonValue", json.dumps([app.conn_ref(MCP_NAME)]))
f("sa", "activity", f"{S}.remoteAgents", "--jsonValue",
  json.dumps([app.conn_ref(f"{name}A2AServer") for name, _ in AGENTS]))

print("== mappings ==")
f("mm", f"{FLOW}.AIAgent.input.userPrompt", "=coerce.toString($flow.content)")
f("mm", f"{FLOW}.AIAgent.input.conversationId", '=$flow.headers["Sec-Websocket-Key"]')
f("mm", f"{FLOW}.WebsocketWriteData.input.message", "=$activity[AIAgent].response")
f("mm", f"{FLOW}.WebsocketWriteData.input.wsconnection", "=$flow.wsconnection")

print("== handler + wsserver fixes ==")
f("cth", FLOW, "WebsocketServer", "Aurelia Global Bank chat handler")
f("sa", "handler", f"WebsocketServer.{FLOW}.settings.path", WS_PATH)
f("sa", "handler", f"WebsocketServer.{FLOW}.settings.mode", "Data")
f("sa", "handler", f"WebsocketServer.{FLOW}.settings.format", "String")
f("wth", FLOW, f"WebsocketServer.{FLOW}", "--force",
  "--input", "content:any,wsconnection:any,pathParams:params,queryParams:params,headers:object", "--inputs-only")
HDR_NAMES = ["Accept", "Accept-Charset", "Accept-Encoding", "Content-Type", "Content-Length", "Connection",
             "Cookie", "Pragma", "Sec-Websocket-Key", "Sec-Websocket-Version", "Upgrade"]
hprops = {k: {"type": "string", "visible": False} for k in HDR_NAMES}
hdr = {"type": "object", "properties": hprops, "required": []}
# INLINE, not schema://: the wsserver trigger reads schemas.output.headers["value"] at runtime; a schema:// ref
# has no "value", so no header reaches $flow.headers. fe_metadata is the designer's parameter-list format, not a
# copy of value, or the designer's Sync rewrites value to zero headers (see runtime-gotchas.md).
hfe = [{"parameterName": k, "type": "string", "repeating": "false", "required": "false", "visible": False}
       for k in HDR_NAMES]
f("sa", "handler", f"WebsocketServer.{FLOW}.schemas.output.headers", "--jsonValue",
  json.dumps({"type": "json", "value": json.dumps(hdr, separators=(",", ":")),
              "fe_metadata": json.dumps(hfe, separators=(",", ":"))}), "--force")
f("sa", "flow", f"{FLOW}.metadata.input", "--jsonFile", jtmp(
    [{"name": "pathParams", "type": "params"}, {"name": "queryParams", "type": "params"},
     {"name": "headers", "type": "object",
      "schema": {"type": "json", "value": json.dumps(hprops, separators=(",", ":"))}},
     {"name": "content", "type": "any"}, {"name": "wsconnection", "type": "any"}]), "--force")
f("sa", "flow", f"{FLOW}.metadata.fe_metadata", "--jsonFile", jtmp({"input": json.dumps(
    {"type": "object", "title": "WebsocketServer", "properties": {
        "pathParams": {"type": "params"}, "queryParams": {"type": "params"}, "headers": hdr,
        "content": {"type": "any", "required": False}, "wsconnection": {"type": "any", "required": False}}},
    separators=(",", ":"))}), "--force")

print("== self-check ==")
d = app.load()
props = {p["name"]: p["value"] for p in d["properties"]}
conns = {c["name"]: c for c in (d["connections"].values() if isinstance(d["connections"], dict) else d["connections"])}
ids = {c["id"] for c in conns.values()}
tr = next(t for t in d["triggers"] if t["ref"].endswith("wsserver"))
h = tr["handlers"][0]
agent = next(t for r in d["resources"] for t in r["data"]["tasks"] if t["id"] == "AIAgent")["activity"]
s = agent["settings"]
problems = []
def need(cond, msg):
    if not cond: problems.append(msg)
need(str(props.get("WebSocket_PORT")) in ("9870", "9870.0") and tr["settings"]["port"] == '=$property["WebSocket_PORT"]',
     "ws port")
need(h["settings"].get("path") == WS_PATH, "ws path")
need(agent["input"].get("conversationId") == '=$flow.headers["Sec-Websocket-Key"]', "conversationId mapping")
need(s.get("redactSensitiveData") is False, "redactSensitiveData must be JSON false")
need(s.get("temperature") == 0 and not isinstance(s.get("temperature"), bool), "temperature must be JSON number 0")
need(props.get(f"{MCP_NAME}_URL") == MCP_URL
     and conns[MCP_NAME]["settings"]["serverUrl"] == f'=$property["{MCP_NAME}_URL"]', "MCP URL property")
for name, url in AGENTS:
    need(props.get(f"{name}_URL") == url
         and conns[f"{name}A2AServer"]["settings"]["serverUrl"] == f'=$property["{name}_URL"]', f"{name} URL property")
need(len(s.get("remoteAgents", [])) == 3 and len(s.get("mcpServers", [])) == 1, "remoteAgents/mcpServers arrays")
raw = json.dumps({k: v for k, v in d.items() if k != "connections"})
import re
need(all(c in ids for c in re.findall(r"conn://([\w-]+)", raw)), "dangling conn://")
need("New_value" not in json.dumps(d), "New_value present")
if problems:
    sys.exit("SELF-CHECK FAILED: " + "; ".join(problems))
print("  self-check ok")
print("\nOrchestrator build complete:", app.file)
