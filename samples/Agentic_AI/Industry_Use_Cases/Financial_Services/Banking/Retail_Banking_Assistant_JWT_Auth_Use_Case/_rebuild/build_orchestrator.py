#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# HOW THIS BUILDS THE APP: this script generates the .flogo application with the
# TIBCO Flogo Design CLI (fda / flogodesign-cli), driven programmatically through
# the App wrapper in fda_common.py. It issues fda subcommands (create the app,
# trigger, flow and activities; set links, schemas, app properties and mappings)
# to build the app deterministically -- it does NOT hand-write the .flogo JSON.
# ---------------------------------------------------------------------------
"""Build RetailBankingSecureOrchestrator.flogo with fda only (Kestrel Bank assistant, JWT auth variant).

WebSocket trigger (9970 /retailbanking) -> guard on the handshake's Authorization header -> LLM Client activity
(per-call LLM, MCP and A2A configs, no connection resources) -> WebSocket write.

  Flow  Orchestrator_Flow
    StartActivity --[Authorization starts with "Bearer "]--> LLMClient --> WriteResponse
    StartActivity --[no / malformed Authorization]-------> SignInRequired          (fixed reply, no LLM call)
    LLMClient ==[error]==> LogLLMClientError --[MCP server auth failure]--> SignInExpired (fixed "sign in again" reply)
                                             --[anything else]-------> ServiceUnavailable (fixed reply)

  MCP server  mcpServerConfigs[0]  $property["MCP.URL"]  http://localhost:9972/retail-banking-mcp
              authType "Token", authToken = the caller's JWT (Authorization header minus "Bearer ")
  A2A agents  a2aServerConfigs[0..2]  authType "Static Token", authToken = $property["A2A.<agent>.AuthToken"]
              dispute_triage_agent 9973, scam_signal_agent 9974, hardship_intake_agent 9975 ($property["A2A.<agent>.URL"])

The JWT is read ONLY from the WebSocket handshake's Authorization header (declared in the handler's header schema;
the wsserver trigger looks headers up by canonical name, so "authorization:" also matches). Query parameters are
never read. The token is a transport input of the LLM Client, never prompt text, so the model never sees it.
Memory: conversationId = the connection's Sec-Websocket-Key (one conversation per WebSocket connection).
System prompt: _rebuild/orchestrator_prompt.txt -> app property LLMClient.SystemPrompt.

Secrets: the shipped app carries placeholders only (sk-REPLACE-WITH-YOUR-OPENAI-KEY, SET_YOUR_A2A_TOKEN). Supply
real values at run time, e.g. FLOGO_APP_PROPS_ENV=auto LLMClient_API_Key=... A2A_dispute_triage_agent_AuthToken=...

Re-run:  python _rebuild/build_orchestrator.py      (OUT_DIR=<empty dir> to replay; refuses to overwrite)"""
import json, os, re, sys
os.environ.setdefault("PG_DB", "banking_jwt_auth")     # unused here (no DB connection) - keeps fda_common happy
from fda_common import App, LLM, jtmp

APP_NAME = "RetailBankingSecureOrchestrator"
app = App(f"{APP_NAME}.flogo", os.environ.get("OUT_DIR"))
f = app.fda
WS_PORT, WS_PATH = "9970", "/retailbanking"
MCP_NAME, MCP_URL = "RetailBankingSecureMCPServer", "http://localhost:9972/retail-banking-mcp"
AGENTS = [("dispute_triage_agent", "http://localhost:9973"),
          ("scam_signal_agent", "http://localhost:9974"),
          ("hardship_intake_agent", "http://localhost:9975")]
API_KEY_PLACEHOLDER, A2A_TOKEN_PLACEHOLDER = "sk-REPLACE-WITH-YOUR-OPENAI-KEY", "SET_YOUR_A2A_TOKEN"
FLOW = "Orchestrator_Flow"

SYS = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "orchestrator_prompt.txt"),
           encoding="utf-8").read().strip()

# --- expressions -----------------------------------------------------------------------------------------------
# A header the client did not send is ABSENT from $flow.headers, and $flow.headers["X"] on an absent key is a
# runtime error ("Invalid path ... path not found") that fails the whole flow. json.exists() guards it; || and &&
# short-circuit in the Flogo expression engine, so the indexed read only runs when the key exists.
AUTH = 'coerce.toString($flow.headers["Authorization"])'
SIGNED_IN = (f'json.exists($flow.headers, "Authorization") && string.startsWith({AUTH}, "Bearer ") '
             f'&& string.length({AUTH}) > 7')
JWT = f'=string.trimPrefix({AUTH}, "Bearer ")'       # evaluated only on the signed-in branch (header present)
ERR = 'string.toLower(coerce.toString($error[LLMClient].message))'
# MCP 401 on 2.26.7 surfaces as: failed to connect to dynamic MCP server '<name>' at <url>. reason=[... operation
# 'Connect' failed (AUTHENTICATION_ERROR): calling "initialize": sending "initialize": Unauthorized]  (no "401").
# AUTHENTICATION_ERROR is the SDK's class for unauthorized / forbidden / invalid token. The match is limited to errors
# that name the MCP server: an LLM provider 401 (e.g. a wrong LLMClient.API_Key) must NOT be reported to the user as
# an expired sign-in - it takes the generic ServiceUnavailable reply instead.
AUTH_ERR = (f'string.contains({ERR}, "mcp server") && (string.contains({ERR}, "authentication_error") '
            f'|| string.contains({ERR}, "unauthorized"))')

MSG_SIGN_IN = ("Please sign in to Kestrel Bank to use the assistant. This chat did not receive your sign-in, so "
               "nothing has been looked up or changed. Sign in, then start a new chat.")
MSG_EXPIRED = ("Your sign-in is not valid or has expired. Please sign in to Kestrel Bank again, then start a new "
               "chat.")
# No "nothing has been changed" here: the LLM call can fail after a tool already ran in the same turn.
MSG_UNAVAILABLE = ("Sorry, the assistant ran into a problem and could not finish your request. Please try again in a "
                   "few minutes, or call Kestrel Bank.")

print("== project + app properties ==")
f("cp", APP_NAME,
  "Kestrel Bank AI orchestrator (JWT auth variant) - WebSocket chat for signed-in customers and staff reviewers; "
  "LLM Client activity carries the caller's JWT to the MCP server")
f("cap", "WebSocket_PORT", "number", WS_PORT)
f("cap", "LLMClient.LLM_Provider", "string", LLM["provider"])
f("cap", "LLMClient.API_Key", "string", API_KEY_PLACEHOLDER)
f("cap", "LLMClient.LLM_Model", "string", LLM["model"])
if LLM["base_url"]: f("cap", "LLMClient.LLM_Base_URL", "string", LLM["base_url"])
else:               app.cap_empty("LLMClient.LLM_Base_URL")
f("cap", "LLMClient.SystemPrompt", "string", SYS)
f("cap", "MCP.URL", "string", MCP_URL)
for name, url in AGENTS:
    f("cap", f"A2A.{name}.URL", "string", url)
    f("cap", f"A2A.{name}.AuthToken", "string", A2A_TOKEN_PLACEHOLDER)

print("== trigger + flow + activities ==")
f("ct", "WebsocketServer", "tr_wsserver", "WebSocket server")
f("sa", "trigger", "WebsocketServer.settings.port", "WebSocket_PORT", "-C", "app-property")
f("cf", FLOW, "Kestrel Bank secure orchestrator: Bearer guard -> LLM Client (caller JWT to MCP) -> reply")
for task, typ, desc in [
        ("LLMClient", "act_agenticai_llmclientactivity",
         "LLM Client: per-call LLM, MCP (caller JWT) and A2A (static token) configs, memory per connection"),
        ("WriteResponse", "act_websocket_wswritedata", "Write the assistant's answer to the WebSocket"),
        ("SignInRequired", "act_websocket_wswritedata",
         "No Authorization: Bearer header on the handshake - fixed sign-in reply, no LLM call"),
        ("LogLLMClientError", "act_general_log", "Log why the LLM Client failed (operator diagnostics)"),
        ("SignInExpired", "act_websocket_wswritedata",
         "The MCP server rejected the caller's JWT - fixed 'sign in again' reply"),
        ("ServiceUnavailable", "act_websocket_wswritedata",
         "Any other LLM Client failure - fixed 'temporarily unavailable' reply")]:
    f("ca", FLOW, task, typ, desc, "--doNotLink")

print("== links (stored in topological order: the designer drops tasks whose incoming link precedes its source's) ==")
# exprOtherwise = the designer's "Success with no matching condition": taken when no sibling condition is true.
LINKS = [("StartActivity", "LLMClient", "expression", "Signed in (Bearer token)", SIGNED_IN),
         ("StartActivity", "SignInRequired", "exprOtherwise", "Not signed in", None),
         ("LLMClient", "WriteResponse", "label", "LLMClient to WriteResponse", None),
         ("LLMClient", "LogLLMClientError", "error", "LLM Client failed", None),
         ("LogLLMClientError", "SignInExpired", "expression", "MCP server rejected the sign-in", AUTH_ERR),
         ("LogLLMClientError", "ServiceUnavailable", "exprOtherwise", "Other failure", None)]
def existing_links():
    fl = next(r for r in app.load()["resources"] if r["id"] == f"flow:{FLOW}")["data"]
    return [(l["from"], l["to"]) for l in fl.get("links", [])]
for i, (a, b, typ, label, cond) in enumerate(LINKS):
    if (a, b) not in existing_links():      # fda links the first task to StartActivity even with --doNotLink
        f("cl", FLOW, a, b)
    need_pos = existing_links().index((a, b))
    if need_pos != i: sys.exit(f"link order: {a}->{b} stored at {need_pos}, expected {i}")
    f("sa", "flow", f"{FLOW}.links[{i}].label", label)
    if typ != "label":
        f("sa", "flow", f"{FLOW}.links[{i}].type", typ)
    if cond:
        f("sa", "flow", f"{FLOW}.links[{i}].value", cond, "--force")

print("== LLM Client settings ==")
S = f"{FLOW}.LLMClient.settings"
f("sa", "activity", f"{S}.responseType", "Text")
f("sa", "activity", f"{S}.conversationStoreType", "Memory")
f("sa", "activity", f"{S}.memoryMaxSize", "--jsonValue", "60")

print("== LLM Client inputs (all per call, from app properties + the handshake header) ==")
P = lambda name: f'=$property["{name}"]'
llm_inputs = {
    "systemPrompt": P("LLMClient.SystemPrompt"),
    "userPrompt": "=coerce.toString($flow.content)",
    "conversationId": '=$flow.headers["Sec-Websocket-Key"]',
    "llmConfiguration": {"mapping": {
        "provider": P("LLMClient.LLM_Provider"), "apiKey": P("LLMClient.API_Key"),
        "model": P("LLMClient.LLM_Model"), "providerBaseUrl": P("LLMClient.LLM_Base_URL"), "temperature": 0}},
    "mcpServerConfigs": {"mapping": [{
        "name": MCP_NAME, "serverType": "http", "serverUrl": P("MCP.URL"), "httpTransportType": "streamable",
        "authType": "Token", "authToken": JWT}]},
    "a2aServerConfigs": {"mapping": [{
        "name": name, "serverUrl": P(f"A2A.{name}.URL"), "authType": "Static Token",
        "authToken": P(f"A2A.{name}.AuthToken")} for name, _ in AGENTS]},
}
f("sa", "activity", f"{FLOW}.LLMClient.input", "--jsonFile", jtmp(llm_inputs), "--force")
D4 = "http://json-schema.org/draft-04/schema#"
def obj(props): return {"type": "object", "properties": {k: {"type": t} for k, t in props}}
llm_schema = {"$schema": D4, **obj([("provider", "string"), ("apiKey", "string"), ("model", "string"),
                                    ("providerBaseUrl", "string"), ("temperature", "number"),
                                    ("azureDeployment", "string"), ("azureApiVersion", "string"),
                                    ("azureRegion", "string"), ("azureResourceName", "string")])}
mcp_schema = {"$schema": D4, "type": "array", "items": obj([("name", "string"), ("serverType", "string"),
              ("serverUrl", "string"), ("httpTransportType", "string"), ("authType", "string"),
              ("authToken", "string")])}
a2a_schema = {"$schema": D4, "type": "array", "items": obj([("name", "string"), ("serverUrl", "string"),
              ("authType", "string"), ("authToken", "string")])}
llm_sample = {"provider": LLM["provider"], "apiKey": "", "model": LLM["model"], "providerBaseUrl": "",
              "temperature": 0, "azureDeployment": "", "azureApiVersion": "", "azureRegion": "",
              "azureResourceName": ""}
mcp_sample = [{"name": MCP_NAME, "serverType": "http", "serverUrl": MCP_URL, "httpTransportType": "streamable",
               "authType": "Token", "authToken": "<the caller's JWT from the Authorization header>"}]
a2a_sample = [{"name": name, "serverUrl": url, "authType": "Static Token",
               "authToken": f"<resolved at runtime from A2A.{name}.AuthToken>"} for name, url in AGENTS]
C = lambda o: json.dumps(o, separators=(",", ":"))
f("sa", "activity", f"{FLOW}.LLMClient.schemas", "--jsonFile", jtmp({"input": {
    "llmConfiguration": {"type": "json", "value": C(llm_schema), "fe_metadata": C(llm_sample)},
    "mcpServerConfigs": {"type": "json", "value": C(mcp_schema), "fe_metadata": C(mcp_sample)},
    "a2aServerConfigs": {"type": "json", "value": C(a2a_schema), "fe_metadata": C(a2a_sample)}}}), "--force")

print("== replies + error log ==")
for task, msg in [("WriteResponse", "=$activity[LLMClient].response"), ("SignInRequired", MSG_SIGN_IN),
                  ("SignInExpired", MSG_EXPIRED), ("ServiceUnavailable", MSG_UNAVAILABLE)]:
    f("mm", f"{FLOW}.{task}.input.message", msg)
    f("mm", f"{FLOW}.{task}.input.wsconnection", "=$flow.wsconnection")
# The error text names the failing server/URL and the HTTP status; it never contains the bearer token.
f("mm", f"{FLOW}.LogLLMClientError.input.Log Level", "ERROR")
f("mm", f"{FLOW}.LogLLMClientError.input.message",
  '=string.concat("[RetailBankingSecureOrchestrator] LLM Client failed: ", coerce.toString($error[LLMClient].message))')

print("== handler + wsserver wiring ==")
f("cth", FLOW, "WebsocketServer", "Kestrel Bank secure chat handler")
f("sa", "handler", f"WebsocketServer.{FLOW}.settings.path", WS_PATH)
f("sa", "handler", f"WebsocketServer.{FLOW}.settings.mode", "Data")
f("sa", "handler", f"WebsocketServer.{FLOW}.settings.format", "String")
f("wth", FLOW, f"WebsocketServer.{FLOW}", "--force",
  "--input", "content:any,wsconnection:any,pathParams:params,queryParams:params,headers:object", "--inputs-only")
# Authorization is declared (not required: a missing header must reach the flow's sign-in branch, not fail the
# handshake with a bare HTTP 400). The trigger only copies DECLARED headers into $flow.headers.
HDR_NAMES = ["Authorization", "Accept", "Accept-Charset", "Accept-Encoding", "Content-Type", "Content-Length",
             "Connection", "Cookie", "Pragma", "Sec-Websocket-Key", "Sec-Websocket-Version", "Upgrade"]
VISIBLE = {"Authorization"}
hprops = {k: {"type": "string", "visible": k in VISIBLE} for k in HDR_NAMES}
hdr = {"type": "object", "properties": hprops, "required": []}
# INLINE, not schema://: the wsserver trigger reads schemas.output.headers["value"] at runtime; a schema:// ref
# has no "value", so no header reaches $flow.headers. fe_metadata is the designer's parameter-list format.
hfe = [{"parameterName": k, "type": "string", "repeating": "false", "required": "false", "visible": k in VISIBLE}
       for k in HDR_NAMES]
f("sa", "handler", f"WebsocketServer.{FLOW}.schemas.output.headers", "--jsonValue",
  json.dumps({"type": "json", "value": C(hdr), "fe_metadata": C(hfe)}), "--force")
f("sa", "flow", f"{FLOW}.metadata.input", "--jsonFile", jtmp(
    [{"name": "pathParams", "type": "params"}, {"name": "queryParams", "type": "params"},
     {"name": "headers", "type": "object", "schema": {"type": "json", "value": C(hprops)}},
     {"name": "content", "type": "any"}, {"name": "wsconnection", "type": "any"}]), "--force")
f("sa", "flow", f"{FLOW}.metadata.fe_metadata", "--jsonFile", jtmp({"input": C(
    {"type": "object", "title": "WebsocketServer", "properties": {
        "pathParams": {"type": "params"}, "queryParams": {"type": "params"}, "headers": hdr,
        "content": {"type": "any", "required": False}, "wsconnection": {"type": "any", "required": False}}})}),
  "--force")

print("== imports for functions used only in link conditions ==")
d = app.load()
have = " ".join(d["imports"])
for pkg in ("string", "coerce", "json"):
    if f"github.com/project-flogo/contrib/function/{pkg}" not in have:
        # json is missing from fda 0.9.3's import config (only its alias is listed) -> --force; flogobuild resolves it
        f("ai", f"github.com/project-flogo/contrib/function/{pkg}", "--force")

print("== self-check ==")
d = app.load()
props = {p["name"]: p["value"] for p in d["properties"]}
tr = next(t for t in d["triggers"] if t["ref"].endswith("wsserver"))
h = tr["handlers"][0]
flow = next(r for r in d["resources"] if r["id"] == f"flow:{FLOW}")["data"]
tasks = {t["id"]: t["activity"] for t in flow["tasks"]}
llm = tasks["LLMClient"]
problems = []
def need(cond, msg):
    if not cond: problems.append(msg)
need(str(props.get("WebSocket_PORT")) in (WS_PORT, WS_PORT + ".0") and
     tr["settings"]["port"] == '=$property["WebSocket_PORT"]', "ws port")
need(h["settings"].get("path") == WS_PATH, "ws path")
need("Authorization" in json.loads(h["schemas"]["output"]["headers"]["value"])["properties"], "Authorization header")
need(llm["ref"].endswith("llmclientactivity"), "LLM Client ref")
need(llm["settings"].get("conversationStoreType") == "Memory" and llm["settings"].get("memoryMaxSize") == 60, "memory")
need(llm["input"].get("conversationId") == '=$flow.headers["Sec-Websocket-Key"]', "conversationId mapping")
mcp = llm["input"]["mcpServerConfigs"]["mapping"]
need(len(mcp) == 1 and mcp[0]["authType"] == "Token" and mcp[0]["authToken"] == JWT, "MCP config / caller JWT")
a2a = llm["input"]["a2aServerConfigs"]["mapping"]
need([a["name"] for a in a2a] == [n for n, _ in AGENTS] and all(a["authType"] == "Static Token" for a in a2a),
     "A2A configs")
temp = llm["input"]["llmConfiguration"]["mapping"]["temperature"]
need(temp == 0 and not isinstance(temp, bool), "temperature must be JSON number 0")
need(props.get("LLMClient.API_Key") == API_KEY_PLACEHOLDER and
     all(props.get(f"A2A.{n}.AuthToken") == A2A_TOKEN_PLACEHOLDER for n, _ in AGENTS), "placeholders only")
need(props.get("LLMClient.SystemPrompt") == SYS, "system prompt property")
need([(l["from"], l["to"], l["type"], l.get("value")) for l in flow["links"]] ==
     [(a, b, t, c) for a, b, t, _, c in LINKS], "links")
raw = json.dumps(d)
need("queryParams." not in raw and 'queryParams["' not in raw, "nothing may read query params")
need(not d.get("connections"), "no connection resources expected")
need("New_value" not in raw, "New_value present")
need(not re.search(r"sk-(?!REPLACE)[A-Za-z0-9_-]{16,}", raw), "live OpenAI key present")
if problems:
    sys.exit("SELF-CHECK FAILED: " + "; ".join(problems))
print("  self-check ok")
print("\nOrchestrator build complete:", app.file)
