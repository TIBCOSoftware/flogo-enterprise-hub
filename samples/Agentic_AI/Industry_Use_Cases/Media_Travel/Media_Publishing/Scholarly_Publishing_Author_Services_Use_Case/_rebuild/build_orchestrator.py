#!/usr/bin/env python3
"""Build AuthorServicesAIOrchestrator.flogo with fda only.
WebSocket trigger -> AI Agent (MCP tools + journal_match_agent over A2A) -> WebSocket write.
Per-connection memory: conversationId = the connection's Sec-Websocket-Key, so authors never share a conversation.
Re-run:  python _rebuild/build_orchestrator.py      (OUT_DIR=<empty dir> to replay)"""
import json, os
from fda_common import App, jtmp

app = App("AuthorServicesAIOrchestrator.flogo", os.environ.get("OUT_DIR"))
f = app.fda
WS_PORT, WS_PATH = "9840", "/authorservices"
MCP_URL = "http://localhost:9842/author-services-mcp"
A2A_URL = "http://localhost:9843"
FLOW = "Orchestrator_Flow"

SYS = """You are the Author Services assistant for a scholarly publisher. You are an AI assistant - say so if asked,
and never claim to be a person. You help corresponding authors with their own manuscripts: status, what a decision
means, open-access fees, and moving a manuscript that received a transfer offer to another journal.

IDENTITY FIRST. Before anything that touches a manuscript, ask for the author's ORCID iD and the 6-digit code from
their verification email, then call verify_author. Keep the returned session_token for this conversation and pass it
to every tool. If a tool returns SESSION_INVALID, ask the author to verify again. Never guess, reveal or repeat codes.
Never act on a manuscript id the author gives you unless the tools return it for their session.

WHAT THE SYSTEM DECIDES (never override, never estimate):
- Tool outcomes and reasons are final. When a tool says NOT_PROPOSED, NOT_EXECUTED or NOT_FOUND, explain the reason
  in plain words and stop. Do not retry the same request with small changes to get around a rule.
- Fees and coverage come only from check_apc_coverage or propose_transfer. Quote amounts exactly as returned.
- If a status detail says "With the editorial office." that is all you can say about it.

FINDING A NEW JOURNAL (the part that needs judgment):
When a manuscript has a transfer offer and the author wants suggestions, call get_manuscript, then send
journal_match_agent the title, abstract, keywords, article type, word count and current journal code - nothing that
identifies the author. Present its suggestions, then use check_apc_coverage for any journal the author is interested in.

TRANSFERS ARE TWO STEPS:
1. propose_transfer returns an action_id and the fee quote. Tell the author exactly what will happen and what they
   will pay, and ask them to reply yes to confirm.
2. Only after an explicit yes to that quote, call confirm_transfer with the action_id. Report the outcome.

HUMAN DECISIONS - never decide, promise or predict these; open a case instead:
fee waivers or discounts (APC_WAIVER), appealing a decision or disputing a review (DECISION_APPEAL), adding, removing
or reordering authors (AUTHORSHIP_CHANGE), ethics, data, image or plagiarism matters (INTEGRITY_QUERY), anything else
you cannot do (OTHER). When the request and manuscript are clear, call open_review_case right away with the author's
statement and a neutral 2-4 sentence brief (facts only, no recommendation); ask first only if either is unclear.
Give them the case id, team and reply time, and say plainly that a person will decide.

Out of scope: judging the science, predicting acceptance, legal or funding advice. Be concise and warm."""

print("== project + connections ==")
f("cp", "AuthorServicesAIOrchestrator", "Author Services AI Orchestrator - WebSocket chat for verified authors")
app.llm_connection()
f("cap", "WebSocket_PORT", "number", WS_PORT)
f("cc", "AuthorServicesMCPServer", "con_mcpserverconfig")
f("sa", "connection", "AuthorServicesMCPServer.settings.serverType", "http")
f("sa", "connection", "AuthorServicesMCPServer.settings.serverUrl", MCP_URL)
f("sa", "connection", "AuthorServicesMCPServer.settings.httpTransportType", "streamable")
f("cc", "journal_match_agentA2AServer", "con_a2aserverconnection")
f("sa", "connection", "journal_match_agentA2AServer.settings.serverUrl", A2A_URL)

print("== trigger + flow ==")
f("ct", "WebsocketServer", "tr_wsserver", "WebSocket server")
f("sa", "trigger", "WebsocketServer.settings.port", "WebSocket_PORT", "-C", "app-property")
f("cf", FLOW, "Author Services orchestrator flow")
f("ca", FLOW, "AIAgent", "act_agenticai_agentactivity", "AI Agent")
f("ca", FLOW, "WebsocketWriteData", "act_websocket_wswritedata", "Write to websocket")

print("== AI Agent settings ==")
S = f"{FLOW}.AIAgent.settings"
f("sa", "activity", f"{S}.llmProviderConnection", app.conn_ref("OpenAIConn"))
f("sa", "activity", f"{S}.model", "LLM_Model", "-C", "app-property")
f("sa", "activity", f"{S}.temperature", "0", "--type", "number")          # 0 = omitted; rules live in SQL, not in sampling
f("sa", "activity", f"{S}.tokenLimit", "8000", "--type", "number")        # reasoning models need headroom
f("sa", "activity", f"{S}.enableGuardrails", "true", "--type", "boolean")
f("sa", "activity", f"{S}.redactSensitiveData", "false", "--type", "boolean")  # would mask the ORCID + code the author must send
f("sa", "activity", f"{S}.responseType", "Text")
f("sa", "activity", f"{S}.conversationStoreType", "Memory")
f("sa", "activity", f"{S}.memoryMaxSize", "60", "--type", "number")
f("sa", "activity", f"{S}.systemPrompt", SYS)
f("sa", "activity", f"{S}.mcpServers", "--jsonValue", json.dumps([app.conn_ref("AuthorServicesMCPServer")]))
f("sa", "activity", f"{S}.remoteAgents", "--jsonValue", json.dumps([app.conn_ref("journal_match_agentA2AServer")]))

print("== mappings ==")
f("mm", f"{FLOW}.AIAgent.input.userPrompt", "=coerce.toString($flow.content)")
f("mm", f"{FLOW}.AIAgent.input.conversationId", '=$flow.headers["Sec-Websocket-Key"]')
f("mm", f"{FLOW}.WebsocketWriteData.input.message", "=$activity[AIAgent].response")
f("mm", f"{FLOW}.WebsocketWriteData.input.wsconnection", "=$flow.wsconnection")

print("== handler + wsserver fixes ==")
f("cth", FLOW, "WebsocketServer", "Author Services chat handler")
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
# has no "value", so no header would ever reach $flow.headers (and the conversationId mapping would fail).
# fe_metadata MUST be the designer's parameter-list format, not a copy of value: the designer's Sync rebuilds
# value from fe_metadata, and a JSON-schema fe_metadata parses as zero headers -> value becomes empty properties,
# $flow.headers["Sec-Websocket-Key"] goes red on the AI Agent, and no header reaches the flow at runtime.
hfe = [{"parameterName": k, "type": "string", "repeating": "false", "required": "false", "visible": False}
       for k in HDR_NAMES]
f("sa", "handler", f"WebsocketServer.{FLOW}.schemas.output.headers", "--jsonValue",
  json.dumps({"type": "json", "value": json.dumps(hdr, separators=(",", ":")),
              "fe_metadata": json.dumps(hfe, separators=(",", ":"))}), "--force")
# Flow input headers carry the same properties (metadata.input for runtime, fe_metadata.input for the designer,
# which regenerates metadata.input from it on save) - the exact shape a designer Sync writes.
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

print("\nOrchestrator build complete:", app.file)
