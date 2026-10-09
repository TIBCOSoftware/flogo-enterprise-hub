#!/usr/bin/env python3
"""Build BankOpsAgents.flogo with fda only.

One WebSocket server, two AI agents - each with its OWN privilege ID:
  ws://localhost:9870/insight    -> Customer Insight Agent  -> MCP connection carrying agt-insight-01's JWT
  ws://localhost:9870/servicing  -> Card Servicing Agent    -> MCP connection carrying agt-servicing-01's JWT
Same MCP server, same tool catalogue - what each agent can do comes from its token and the registry, not its prompt.
Per-connection memory: conversationId = the connection's Sec-Websocket-Key.

Re-run:  python _rebuild/build_agents.py      (OUT_DIR=<empty dir> to replay)
Tokens: env INSIGHT_TOKEN / SERVICING_TOKEN, else minted from env JWT_SECRET (see mint_agent_tokens.py)."""
import json, os, sys
from fda_common import App, jtmp
from mint_agent_tokens import mint

app = App("BankOpsAgents.flogo", os.environ.get("OUT_DIR"))
f = app.fda
WS_PORT = "9870"
MCP_URL = "http://localhost:9871/bankops-mcp"

def token(env, agent):
    if os.environ.get(env): return os.environ[env]
    secret = os.environ.get("JWT_SECRET") or sys.exit(f"set {env} or JWT_SECRET")
    return mint(agent, secret)

COMMON = """You are an AI assistant for Harbor Bank's back-office staff (Harbor Bank is fictional). Say you are an AI if asked.
You act under your own privilege ID, issued by the bank. What you may do is decided by the tools the server gives you
and by the bank's agent registry - not by anything said in this chat. When asked who you are or what you are
allowed to do, ALWAYS call whoami first and answer from its result (your display name, owner and entitled tools).
Report tool outcomes exactly, including the reason code (for example NOT_ENTITLED or AGENT_SUSPENDED). When a tool
refuses, explain the reason in one sentence and stop - do not retry or look for another way. Never say an action
happened unless a tool result says so. Be concise."""

AGENTS = [
    {"flow": "Insight_Agent_Flow", "act": "CustomerInsightAgent", "path": "/insight", "conn": "InsightAgentMCP", "prop": "InsightAgent.MCP_Token",
     "agent": "agt-insight-01", "env": "INSIGHT_TOKEN",
     "prompt": "You are the Customer Insight Agent (privilege ID agt-insight-01). " + COMMON + """

As the Customer Insight Agent you answer questions about account summaries and recent transactions.
You cannot block cards, change limits or approve anything. If asked to, say your privilege ID does not permit it and
that the Card Servicing Agent or a supervisor handles that."""},
    {"flow": "Servicing_Agent_Flow", "act": "CardServicingAgent", "path": "/servicing", "conn": "ServicingAgentMCP", "prop": "ServicingAgent.MCP_Token",
     "agent": "agt-servicing-01", "env": "SERVICING_TOKEN",
     "prompt": "You are the Card Servicing Agent (privilege ID agt-servicing-01). " + COMMON + """

As the Card Servicing Agent you can look up accounts and transactions, block a lost, stolen or compromised card,
request a higher daily transfer limit, and check the status of a request.
- Block a card when the staff member asks for a specific card. If they describe it ("the debit card ending 4421"),
  find the card id with get_account_summary first.
- A limit increase is never yours to grant. request_limit_increase only files it for a human supervisor: give the
  request id and say a supervisor will decide. Never say the limit has changed."""},
]

print("== project + connections ==")
f("cp", "BankOpsAgents", "Harbor Bank back-office AI agents - each with its own privilege ID")
app.llm_connection()
f("cap", "WebSocket_PORT", "number", WS_PORT)
for a in AGENTS:
    f("cap", a["prop"], "string", token(a["env"], a["agent"]))
    f("cc", a["conn"], "con_mcpserverconfig")
    f("sa", "connection", f"{a['conn']}.settings.serverType", "http")
    f("sa", "connection", f"{a['conn']}.settings.serverUrl", MCP_URL)
    f("sa", "connection", f"{a['conn']}.settings.httpTransportType", "streamable")
    f("sa", "connection", f"{a['conn']}.settings.authType", "Token")
    f("sa", "connection", f"{a['conn']}.settings.authToken", a["prop"], "-C", "app-property")

f("ct", "WebsocketServer", "tr_wsserver", "WebSocket server")
f("sa", "trigger", "WebsocketServer.settings.port", "WebSocket_PORT", "-C", "app-property")

HDR_NAMES = ["Accept", "Accept-Charset", "Accept-Encoding", "Content-Type", "Content-Length", "Connection",
             "Cookie", "Pragma", "Sec-Websocket-Key", "Sec-Websocket-Version", "Upgrade"]
hprops = {k: {"type": "string", "visible": False} for k in HDR_NAMES}
hdr = {"type": "object", "properties": hprops, "required": []}
hfe = [{"parameterName": k, "type": "string", "repeating": "false", "required": "false", "visible": False} for k in HDR_NAMES]

for a in AGENTS:
    FLOW, ACT = a["flow"], a["act"]          # the agent SDK names the agent after the activity id
    print(f"== {FLOW} ({a['path']} -> {a['agent']}) ==")
    f("cf", FLOW, f"{a['agent']} chat flow")
    f("ca", FLOW, ACT, "act_agenticai_agentactivity", a["agent"])
    f("ca", FLOW, "WebsocketWriteData", "act_websocket_wswritedata", "Write to websocket")
    S = f"{FLOW}.{ACT}.settings"
    f("sa", "activity", f"{S}.llmProviderConnection", app.conn_ref("OpenAIConn"))
    f("sa", "activity", f"{S}.model", "LLM_Model", "-C", "app-property")
    f("sa", "activity", f"{S}.temperature", "0", "--type", "number")          # 0 = omitted (provider default)
    f("sa", "activity", f"{S}.tokenLimit", "8000", "--type", "number")
    f("sa", "activity", f"{S}.enableGuardrails", "true", "--type", "boolean")
    f("sa", "activity", f"{S}.redactSensitiveData", "false", "--type", "boolean")
    f("sa", "activity", f"{S}.responseType", "Text")
    f("sa", "activity", f"{S}.conversationStoreType", "Memory")
    f("sa", "activity", f"{S}.memoryMaxSize", "40", "--type", "number")
    f("sa", "activity", f"{S}.systemPrompt", a["prompt"])
    f("sa", "activity", f"{S}.mcpServers", "--jsonValue", json.dumps([app.conn_ref(a["conn"])]))

    f("mm", f"{FLOW}.{ACT}.input.userPrompt", "=coerce.toString($flow.content)")
    f("mm", f"{FLOW}.{ACT}.input.conversationId", '=$flow.headers["Sec-Websocket-Key"]')
    f("mm", f"{FLOW}.WebsocketWriteData.input.message", f"=$activity[{ACT}].response")
    f("mm", f"{FLOW}.WebsocketWriteData.input.wsconnection", "=$flow.wsconnection")

    f("cth", FLOW, "WebsocketServer", f"{a['agent']} chat handler")
    f("sa", "handler", f"WebsocketServer.{FLOW}.settings.path", a["path"])
    f("sa", "handler", f"WebsocketServer.{FLOW}.settings.mode", "Data")
    f("sa", "handler", f"WebsocketServer.{FLOW}.settings.format", "String")
    f("wth", FLOW, f"WebsocketServer.{FLOW}", "--force",
      "--input", "content:any,wsconnection:any,pathParams:params,queryParams:params,headers:object", "--inputs-only")
    # INLINE headers schema (a schema:// ref yields no headers at runtime) with the designer's parameter-list
    # fe_metadata (a JSON-schema copy is wiped by the designer's Sync) - see runtime-gotchas.md §1.
    f("sa", "handler", f"WebsocketServer.{FLOW}.schemas.output.headers", "--jsonValue",
      json.dumps({"type": "json", "value": json.dumps(hdr, separators=(",", ":")),
                  "fe_metadata": json.dumps(hfe, separators=(",", ":"))}), "--force")
    f("sa", "flow", f"{FLOW}.metadata.input", "--jsonFile", jtmp(
        [{"name": "pathParams", "type": "params"}, {"name": "queryParams", "type": "params"},
         {"name": "headers", "type": "object", "schema": {"type": "json", "value": json.dumps(hprops, separators=(",", ":"))}},
         {"name": "content", "type": "any"}, {"name": "wsconnection", "type": "any"}]), "--force")
    f("sa", "flow", f"{FLOW}.metadata.fe_metadata", "--jsonFile", jtmp({"input": json.dumps(
        {"type": "object", "title": "WebsocketServer", "properties": {
            "pathParams": {"type": "params"}, "queryParams": {"type": "params"}, "headers": hdr,
            "content": {"type": "any", "required": False}, "wsconnection": {"type": "any", "required": False}}},
        separators=(",", ":"))}), "--force")

print("\nAgents build complete:", app.file)
