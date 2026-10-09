#!/usr/bin/env python3
"""Build BankOpsOrchestrator.flogo with fda only: the front-door agent, using the LLM Client activity.

  WebSocket :9880 /bankops -> LLM Client activity -> WebSocket write
  - llmConfiguration and mcpServerConfigs are runtime INPUTS (no LLM / MCP connection resources).
  - Its only MCP server is BankOpsSpecialists, reached with the orchestrator's OWN JWT (agt-orchestrator-01,
    scopes agent:insight + agent:servicing, signed with SPECIALISTS_JWT_SECRET). It holds no bank-system token.
  - Per-connection memory: conversationId = the connection's Sec-Websocket-Key.

Re-run:  python orchestrated/_rebuild/build_orchestrator.py   (OUT_DIR=<empty dir> to replay)
Needs env SPECIALISTS_JWT_SECRET (or ORCHESTRATOR_TOKEN) and LLM_MODEL; LLM key from env/config.md."""
import json, os
from orch_common import ORCH_DIR, SPECIALISTS_URL, ORCH_WS_PORT, ORCH_WS_PATH, ORCH_PROMPT, secret
from fda_common import App, jtmp, LLM, llm_key
from mint_agent_tokens import mint

app = App("BankOpsOrchestrator.flogo", os.environ.get("OUT_DIR") or ORCH_DIR)
f = app.fda
FLOW, ACT = "Orchestrator_Flow", "OperationsOrchestrator"
token = os.environ.get("ORCHESTRATOR_TOKEN") or mint("agt-orchestrator-01", secret("SPECIALISTS_JWT_SECRET"))

print("== project + properties ==")
f("cp", "BankOpsOrchestrator", "Harbor Bank operations orchestrator (LLM Client) - delegates to specialist agents only")
f("cap", "LLMClient.LLM_Provider", "string", LLM["provider"])
f("cap", "LLMClient.API_Key", "string", llm_key())
f("cap", "LLMClient.LLM_Model", "string", LLM["model"])
if LLM["base_url"]:
    f("cap", "LLMClient.LLM_Base_URL", "string", LLM["base_url"])
else:
    app.cap_empty("LLMClient.LLM_Base_URL")
f("cap", "LLMClient.SystemPrompt", "string", ORCH_PROMPT)
f("cap", "Specialists.MCP_URL", "string", SPECIALISTS_URL)
f("cap", "Orchestrator.MCP_Token", "string", token)
f("cap", "WebSocket_PORT", "number", ORCH_WS_PORT)

print("== trigger + flow ==")
f("ct", "WebsocketServer", "tr_wsserver", "WebSocket server")
f("sa", "trigger", "WebsocketServer.settings.port", "WebSocket_PORT", "-C", "app-property")
f("cf", FLOW, "Operations orchestrator flow")
f("ca", FLOW, ACT, "act_agenticai_llmclientactivity", "agt-orchestrator-01")
f("ca", FLOW, "WebsocketWriteData", "act_websocket_wswritedata", "Write to websocket")

S = f"{FLOW}.{ACT}.settings"
f("sa", "activity", f"{S}.responseType", "Text")
f("sa", "activity", f"{S}.conversationStoreType", "Memory")
f("sa", "activity", f"{S}.memoryMaxSize", "40", "--type", "number")

LLM_SCHEMA = {"$schema": "http://json-schema.org/draft-04/schema#", "type": "object", "properties": {
    k: {"type": "number" if k == "temperature" else "string"} for k in
    ("provider", "apiKey", "model", "providerBaseUrl", "temperature", "azureDeployment", "azureApiVersion",
     "azureRegion", "azureResourceName")}}
MCP_SCHEMA = {"$schema": "http://json-schema.org/draft-04/schema#", "type": "array", "items": {"type": "object", "properties": {
    k: {"type": "string"} for k in ("name", "serverType", "serverUrl", "httpTransportType", "authType", "authToken")}}}
inp = {
    "systemPrompt": '=$property["LLMClient.SystemPrompt"]',
    "userPrompt": "=coerce.toString($flow.content)",
    "conversationId": '=$flow.headers["Sec-Websocket-Key"]',
    "llmConfiguration": {"mapping": {
        "provider": '=$property["LLMClient.LLM_Provider"]', "apiKey": '=$property["LLMClient.API_Key"]',
        "model": '=$property["LLMClient.LLM_Model"]', "providerBaseUrl": '=$property["LLMClient.LLM_Base_URL"]',
        "temperature": 0}},
    "mcpServerConfigs": {"mapping": [{
        "name": "BankOpsSpecialists", "serverType": "http", "serverUrl": '=$property["Specialists.MCP_URL"]',
        "httpTransportType": "streamable", "authType": "Token", "authToken": '=$property["Orchestrator.MCP_Token"]'}]},
}
f("sa", "activity", f"{FLOW}.{ACT}.input", "--jsonFile", jtmp(inp), "--force")
lv, mv = json.dumps(LLM_SCHEMA), json.dumps(MCP_SCHEMA)
f("sa", "activity", f"{FLOW}.{ACT}.schemas", "--jsonFile", jtmp({"input": {
    "llmConfiguration": {"type": "json", "value": lv, "fe_metadata": json.dumps(
        {"provider": "OpenAI", "apiKey": "", "model": "gpt-5.5", "providerBaseUrl": "", "temperature": 0})},
    "mcpServerConfigs": {"type": "json", "value": mv, "fe_metadata": json.dumps([{
        "name": "BankOpsSpecialists", "serverType": "http", "serverUrl": SPECIALISTS_URL, "httpTransportType": "streamable",
        "authType": "Token", "authToken": "<resolved at runtime from Orchestrator.MCP_Token>"}])}}}), "--force")

f("mm", f"{FLOW}.WebsocketWriteData.input.message", f"=$activity[{ACT}].response")
f("mm", f"{FLOW}.WebsocketWriteData.input.wsconnection", "=$flow.wsconnection")

print("== handler + wsserver headers ==")
f("cth", FLOW, "WebsocketServer", "Operations orchestrator chat handler")
f("sa", "handler", f"WebsocketServer.{FLOW}.settings.path", ORCH_WS_PATH)
f("sa", "handler", f"WebsocketServer.{FLOW}.settings.mode", "Data")
f("sa", "handler", f"WebsocketServer.{FLOW}.settings.format", "String")
f("wth", FLOW, f"WebsocketServer.{FLOW}", "--force",
  "--input", "content:any,wsconnection:any,pathParams:params,queryParams:params,headers:object", "--inputs-only")
HDR_NAMES = ["Accept", "Accept-Charset", "Accept-Encoding", "Content-Type", "Content-Length", "Connection",
             "Cookie", "Pragma", "Sec-Websocket-Key", "Sec-Websocket-Version", "Upgrade"]
hprops = {k: {"type": "string", "visible": False} for k in HDR_NAMES}
hdr = {"type": "object", "properties": hprops, "required": []}
hfe = [{"parameterName": k, "type": "string", "repeating": "false", "required": "false", "visible": False} for k in HDR_NAMES]
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

print("\nOrchestrator build complete:", app.file)
