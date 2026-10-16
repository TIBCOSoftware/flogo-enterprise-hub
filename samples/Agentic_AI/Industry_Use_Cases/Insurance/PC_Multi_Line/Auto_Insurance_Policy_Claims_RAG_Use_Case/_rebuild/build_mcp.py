#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# HOW THIS BUILDS THE APP: this script generates the .flogo application with the
# TIBCO Flogo Design CLI (fda / flogodesign-cli), driven programmatically through
# the App wrapper in fda_common.py. It issues fda subcommands (create the app,
# triggers, flows and activities; set schemas, connections, app properties and
# mappings) to build the app deterministically -- it does NOT hand-write the .flogo
# JSON. (The one exception, noted inline where it applies, is the RAG sample, which
# transplants one openAI vector-search activity from a donor app because fda has no
# recipe for user-extension activities.)
# ---------------------------------------------------------------------------
"""Build AutoInsuranceMCPServer.flogo (Copperleaf Auto Insurance / "Riley", governed) - HYBRID CLONE.

1. fda builds all 16 PostgreSQL-backed MCP tools from tool_spec.py (12 customer tools + 4 reviewer tools for the
   human-in-the-loop decision; one server, role checked in SQL). Every tool flow is
       [GuardedWrite (#insert ... SELECT * FROM rule_fn)] -> ReadOutcome (#query) -> Return
   and Return hands ALL readback rows to the MCP caller as {"records":[...]}.
   The email tool sends only when the SQL says send_status == "SEND_OK" (ReadOutcome -> SendMail -> Return, otherwise
   ReadOutcome -> ReturnNotSent); the recipient is the EMAIL_TO app property.
2. search_policy_wording (rag=True in tool_spec.py) is built by fda as  ReadOutcome (SELECT * FROM latest_vector_store())
   -> Return, then the `extensions/openAI` vectorSearch task, its import and its contrib entry are TRANSPLANTED VERBATIM
   from an earlier (pre-governance) AutoInsuranceMCPServer.flogo donor (not included in this repository)
   - fda has no recipe for user-extension activities (SKILL.md Phase 4B "RAG (hybrid
   clone)"). Only vectorStoreID is re-pointed at ReadOutcome (and top 3 results); the flow becomes ReadOutcome -> PolicySearch -> Return.

Building the exe needs the user-extensions flogobuild context (created with `-u <repo>/extensions`).
Re-run:  python _rebuild/build_mcp.py      (needs the auto_insurance_governed DB; OUT_DIR=<empty dir> to replay).
On a mid-run failure, delete ONLY AutoInsuranceMCPServer.flogo and re-run; never touch the other apps."""
import base64, copy, json, os, subprocess
os.environ.setdefault("PG_DB", "auto_insurance_governed")
from fda_common import App, CFG, FDA, USE_CASE_DIR, jtmp, llm_key, result_columns, setting
from tool_spec import TOOLS

app = App("AutoInsuranceMCPServer.flogo", os.environ.get("OUT_DIR"))
f = app.fda
TRIG, PORT, ENDPOINT, SERVER_NAME = "AutoInsuranceMCPServer", "9912", "/autoinsurancemcpserver", "AutoInsuranceMCPServer"
REPO = os.path.abspath(os.path.join(USE_CASE_DIR, *[".."] * 6))
# The vectorSearch donor (an earlier, pre-governance MCP app) is not included in this repository;
# set LEGACY_MCP to a local copy of the original AutoInsuranceMCPServer.flogo to rebuild.
LEGACY_MCP = os.environ.get("LEGACY_MCP", "")
OPENAI_ENDPOINT = "https://api.openai.com/v1"          # the vector extension rejects an empty endpoint

# ---- email settings (config.md "Email Server, Username and app password" section; env wins) ----
EMAIL_USER = setting("EMAIL_USERNAME", "Username")
EMAIL_TO   = os.environ.get("EMAIL_TO") or os.environ.get("TO_EMAIL") or EMAIL_USER
SMTP_HOST  = os.environ.get("SMTP_HOST") or CFG.get("Server") or "smtp.gmail.com"
SMTP_PORT  = os.environ.get("SMTP_PORT") or CFG.get("Port") or "465"
# The #sendmail Password field is password-typed: the designer derives that from a SECRET: prefix, so a plain string
# property fails validation (wrongTypeProp). fda cannot SECRET-encrypt, so use a SECRET: value from env if there is one,
# else a portable dummy blob (re-enter the app password in the designer's App Properties for live SMTP).
DUMMY_SECRET = "SECRET:0llnwBzNtMzA8d+RYoqdf9o6EuE="
_env_pw = os.environ.get("EMAIL_PASSWORD", "")
EMAIL_PASS = _env_pw if _env_pw.startswith("SECRET:") else DUMMY_SECRET
EMAIL_PASS_SRC = "SECRET: value from env" if _env_pw.startswith("SECRET:") else "portable dummy SECRET: blob - re-enter the app password in App Properties"

print("fda:", FDA)
print(subprocess.run([FDA, "version"], capture_output=True, text=True).stdout.strip())
print("email password source:", EMAIL_PASS_SRC)          # never the value itself
if not LEGACY_MCP or not os.path.exists(LEGACY_MCP): raise SystemExit(f"vectorSearch donor not found: {LEGACY_MCP!r}. Set LEGACY_MCP to a local copy of the pre-governance AutoInsuranceMCPServer.flogo.")

print("== project + PostgreSQL ==")
f("cp", TRIG, "Copperleaf Auto Insurance policy and claims MCP Server - scoped reads, guarded writes, RAG policy wording and the reviewer loop")
app.postgres_connection()
f("cap", "MCP_SERVER_PORT", "string", PORT)
# vectorSearch (extensions/openAI) settings - used only by search_policy_wording; scrub the key before publishing
f("cap", "OPENAI_API_KEY", "string", llm_key())
f("cap", "OPENAI_API_ENDPOINT_URL", "string", OPENAI_ENDPOINT)
# email properties (used only by email_confirmation; scrub before publishing)
f("cap", "Email_Username", "string", EMAIL_USER)
f("cap", "Email_App_Password", "string", EMAIL_PASS)
f("cap", "EMAIL_TO", "string", EMAIL_TO)

print("== trigger ==")
f("ct", TRIG, "tr_mcpserver", "Copperleaf Auto Insurance governed MCP server")
f("sa", "trigger", f"{TRIG}.settings.serverType", "HTTP")
f("sa", "trigger", f"{TRIG}.settings.serverPort", "MCP_SERVER_PORT", "-C", "app-property")
f("sa", "trigger", f"{TRIG}.settings.serverEndpointPath", ENDPOINT)
f("sa", "trigger", f"{TRIG}.settings.serverName", SERVER_NAME)
f("sa", "trigger", f"{TRIG}.settings.serverVersion", "1.0.0")
f("cs", "ToolResponse", '{"type":"object","properties":{"data":{"type":"string"},"error":{"type":"string"}}}')

def sendmail_input():
    return {"Server": SMTP_HOST, "Port": int(SMTP_PORT), "authorizationType": "Basic",
            "Username": '=$property["Email_Username"]', "Password": '=$property["Email_App_Password"]',
            "authorizationConn": "", "Connection Security": "SSL", "serverCertificate": "",
            "message_content_type": "text/plain",
            "sender": '=$property["Email_Username"]', "recipients": '=$property["EMAIL_TO"]',
            "cc_recipients": "", "bcc_recipients": "", "reply_to": '=$property["Email_Username"]',
            "subject": '=$activity[ReadOutcome].Output.records[0].subject',
            "message": '=$activity[ReadOutcome].Output.records[0].body'}

SEND_COND = '$activity[ReadOutcome].Output.records[0].send_status == "SEND_OK"'

def flow_links(flow):
    return next(r for r in app.load()["resources"] if r["id"] == "flow:" + flow)["data"]["links"]

def link_index(flow, src, dst):
    return next(i for i, l in enumerate(flow_links(flow)) if l["from"] == src and l["to"] == dst)

def branch_email(flow):
    """ReadOutcome --(send_status == "SEND_OK")--> SendMail --> Return ;  ReadOutcome --(otherwise)--> ReturnNotSent."""
    i = link_index(flow, "ReadOutcome", "SendMail")
    f("sa", "flow", f"{flow}.links[{i}].type", "expression")
    f("sa", "flow", f"{flow}.links[{i}].value", SEND_COND, "--force")     # no leading '=' on link conditions
    f("sa", "flow", f"{flow}.links[{i}].label", "send_status is SEND_OK")
    f("cl", flow, "ReadOutcome", "ReturnNotSent")
    j = link_index(flow, "ReadOutcome", "ReturnNotSent")
    f("sa", "flow", f"{flow}.links[{j}].type", "exprOtherwise")
    f("sa", "flow", f"{flow}.links[{j}].label", "otherwise (NOT_SENT)")
    links = flow_links(flow)
    if links[i].get("type") != "expression" or links[i].get("value") != SEND_COND or links[j].get("type") != "exprOtherwise":
        raise SystemExit(f"FAILED: email branch links not set as expected: {links}")
    if not any(l["from"] == "SendMail" and l["to"] == "Return" for l in links):
        raise SystemExit(f"FAILED: SendMail -> Return link missing: {links}")

RAG_FLOWS = []
for t in TOOLS:
    flow, tool = t["flow"], t["tool"]
    print(f"== tool {tool} ==")
    f("cf", flow, t["desc"])
    if "write" in t:
        f("ca", flow, "GuardedWrite", "act_postgresql_insert", "PostgreSQL Insert", "-C", "PostgresConn")
    f("ca", flow, "ReadOutcome", "act_postgresql_query", "PostgreSQL Query", "-C", "PostgresConn")
    if t.get("email"):
        f("ca", flow, "SendMail", "act_general_sendmail", "Send confirmation email")
    f("ca", flow, "Return", "act_default_actreturn", "Simple Return")
    if t.get("email"):
        f("ca", flow, "ReturnNotSent", "act_default_actreturn", "Return without sending", "--doNotLink")
    arg = lambda a: f"=$flow.arguments.{a}"
    if "write" in t:
        sql, params = t["write"]
        app.bake_pg(flow, "GuardedWrite", "act_postgresql_insert", sql, [(p, arg(a)) for p, a in params])
    sql, params = t["read"]
    app.bake_pg(flow, "ReadOutcome", "act_postgresql_query", sql, [(p, arg(a)) for p, a in params], result_columns(sql))
    if t.get("email"):
        f("sa", "activity", f"{flow}.SendMail.input", "--jsonFile", jtmp(sendmail_input()), "--force")
        branch_email(flow)

    f("cth", flow, TRIG, t["desc"], "--mcpHandlerType", "Tool", "--mcpHandlerName", tool, "--mcpHandlerDescription", t["desc"])
    f("wth", flow, f"{TRIG}.{flow}", "--force")
    props = {a: {"type": "string", "description": d} for a, d in t["args"]}
    req = [a for a, _ in t["args"]]
    f("cs", f"{tool}_Args", json.dumps({"type": "object", "properties": props, "required": req}))
    f("sa", "handler", f"{TRIG}.{flow}.schemas.output.arguments", f"{tool}_Args", "-C", "schema", "--force")
    f("sa", "handler", f"{TRIG}.{flow}.schemas.reply.response", "ToolResponse", "-C", "schema", "--force")
    # MCP hints must be real JSON booleans (--type boolean stores the string "true")
    f("sa", "handler", f"{TRIG}.{flow}.settings.readOnlyToolHint", "--jsonValue", str(t["readonly"]).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.destructiveToolHint", "--jsonValue", str(t.get("destructive", False)).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.idempotentToolHint", "--jsonValue", str(t.get("idempotent", True)).lower())
    # search_policy_wording calls an external service (OpenAI vector store): openWorld = true; DB-only tools: false
    f("sa", "handler", f"{TRIG}.{flow}.settings.openWorldToolHint", "--jsonValue", "true" if t.get("rag") else "false")

    compact = json.dumps({a: {"type": "string"} for a, _ in t["args"]})
    resp = '{"data":{"type":"string"},"error":{"type":"string"}}'
    f("sa", "flow", f"{flow}.metadata.input", "--jsonFile",
      jtmp([{"name": "arguments", "type": "object", "schema": {"type": "json", "value": compact}}]), "--force")
    f("sa", "flow", f"{flow}.metadata.output", "--jsonFile",
      jtmp([{"name": "response", "type": "object", "schema": {"type": "json", "value": resp}}]), "--force")
    fe_in = {"type": "object", "title": TRIG, "properties": {"arguments": {"type": "object", "properties": props, "required": req}}}
    fe_out = {"type": "object", "title": "Inputs", "properties": {"response": {"type": "object", "properties": json.loads(resp)}}, "required": ["response"]}
    f("sa", "flow", f"{flow}.metadata.fe_metadata.input", json.dumps(fe_in), "--force")
    f("sa", "flow", f"{flow}.metadata.fe_metadata.output", json.dumps(fe_out), "--force")

    # all readback rows go back to the caller (several tools return many rows); the RAG flow is re-pointed below
    f("mm", f"{flow}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")
    if t.get("email"):
        f("mm", f"{flow}.ReturnNotSent.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")
    if t.get("rag"):
        RAG_FLOWS.append(flow)

# ---------------------------------------------------------------------------------------------------------------
# Hybrid clone: transplant the extensions/openAI vectorSearch task + import + contrib entry VERBATIM from the legacy app.
# ---------------------------------------------------------------------------------------------------------------
def transplant_vector_search(flow):
    leg = json.load(open(LEGACY_MCP, encoding="utf-8"))
    src = next(t for r in leg["resources"] for t in r["data"].get("tasks", [])
               if t.get("activity", {}).get("ref") == "#vectorSearch")
    imp = next(i for i in leg["imports"] if i.split()[-1].endswith("/extensions/openAI/activity/vectorSearch"))
    leg_contrib = json.loads(base64.b64decode(leg["contrib"]))
    entry = next(e for e in leg_contrib if e.get("id") == "openAI")

    d = app.load()
    res = next(r for r in d["resources"] if r["id"] == "flow:" + flow)["data"]
    task = copy.deepcopy(src)
    task["id"] = task["name"] = "PolicySearch"
    task["description"] = "Semantic search over the Copperleaf policy wording vector store (extensions/openAI vectorSearch)"
    task["activity"]["input"]["vectorStoreID"] = "=$activity[ReadOutcome].Output.records[0].vector_store_id"
    task["activity"]["input"]["searchString"] = "=$flow.arguments.query"
    # top 3 (legacy: 5): chunks are ~800 tokens and every passage stays in the chat memory of that conversation
    task["activity"]["input"]["maxNumberOfResults"] = 3
    # settings stay verbatim: endPointURL / apiKey = $property["OPENAI_API_ENDPOINT_URL"] / $property["OPENAI_API_KEY"]
    if any(t["id"] == "PolicySearch" for t in res["tasks"]): raise SystemExit("PolicySearch already present")
    ret_i = next(i for i, t in enumerate(res["tasks"]) if t["id"] == "Return")
    res["tasks"].insert(ret_i, task)
    link = next(l for l in res["links"] if l["from"] == "ReadOutcome" and l["to"] == "Return")
    link["to"], link["label"] = "PolicySearch", "ReadOutcome to PolicySearch"
    res["links"].append({"id": max(l["id"] for l in res["links"]) + 1, "from": "PolicySearch", "to": "Return",
                         "type": "label", "label": "PolicySearch to Return"})
    ret = res["tasks"][ret_i + 1]
    ret["activity"]["settings"]["mappings"]["response"]["mapping"]["data"] = \
        "=coerce.toString($activity[PolicySearch].searchResultRows)"
    if imp not in d["imports"]: d["imports"].append(imp)
    # contrib: append the openAI entry to the base64 JSON list at the byte level (keeps the other entries' bytes intact)
    raw = base64.b64decode(d["contrib"]).rstrip()
    if b'"id":"openAI"' not in raw.replace(b" ", b""):
        assert raw.endswith(b"]")
        raw = raw[:-1] + b"," + json.dumps(entry, separators=(",", ":")).encode("utf-8") + b"]"
        d["contrib"] = base64.b64encode(raw).decode("ascii")
    with open(app.file, "w", encoding="utf-8") as fh:
        json.dump(d, fh, indent=2, ensure_ascii=False)          # same layout fda writes

    # verify
    d = app.load()
    res = next(r for r in d["resources"] if r["id"] == "flow:" + flow)["data"]
    chain = {(l["from"], l["to"]) for l in res["links"]}
    need = {("ReadOutcome", "PolicySearch"), ("PolicySearch", "Return")}
    if not need <= chain or ("ReadOutcome", "Return") in chain: raise SystemExit(f"FAILED: RAG links {chain}")
    ids = {e["id"] for e in json.loads(base64.b64decode(d["contrib"]))}
    if not {"openAI", "PostgreSQL", "MCP"} <= ids: raise SystemExit(f"FAILED: contrib ids {ids}")
    props = {p["name"] for p in d["properties"]}
    if not {"OPENAI_API_KEY", "OPENAI_API_ENDPOINT_URL"} <= props: raise SystemExit("FAILED: OPENAI_* properties missing")
    print(f"  ok: transplanted vectorSearch into {flow} (import + contrib openAI {entry.get('version')})")

for fl in RAG_FLOWS:
    print(f"== transplant vectorSearch -> {fl} ==")
    transplant_vector_search(fl)

print("\nMCP server build complete:", app.file)
