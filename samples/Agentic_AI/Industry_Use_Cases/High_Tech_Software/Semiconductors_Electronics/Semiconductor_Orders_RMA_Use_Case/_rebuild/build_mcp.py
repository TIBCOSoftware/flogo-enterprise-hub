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
"""Build SemiOrdersMCPServer.flogo with fda only (governed: scoped reads + guarded writes).
Arcwell Components orders & RMA assistant - 21 PostgreSQL-backed MCP tools from tool_spec.py
(17 buyer tools + 4 reviewer tools for the human-in-the-loop decision; one server, role checked in SQL).

Every tool flow is   [GuardedWrite (#insert ... SELECT * FROM rule_fn)] -> ReadOutcome (#query) -> Return,
and Return hands ALL readback rows to the MCP caller as {"records":[...]}.

The email tool is special: ReadOutcome is the SQL-built payload (email_confirmation_payload) and a conditional branch sends the
email ONLY when the SQL says send_status == "SEND_OK":
    ReadOutcome --(send_status == "SEND_OK")--> SendMail --> Return
    ReadOutcome --(otherwise)-------------------------------> ReturnNotSent
Both returns hand back the same readback row. The recipient is the EMAIL_TO app property (the demo stand-in for the
buyer's email on file); the SQL decides the content and the reported outcome, so an unauthorised call sends nothing.

Re-run:  python _rebuild/build_mcp.py      (needs the semiconductor_governed DB; OUT_DIR=<empty dir> to replay).
Chunked build (keeps each run short): BUILD_TO=<n> builds the project + the first n tools; RESUME_FROM=<n> continues on
the existing file from tool n (0-based). On a mid-run failure, delete ONLY SemiOrdersMCPServer.flogo and re-run."""
import json, os, subprocess
os.environ.setdefault("PG_DB", "semiconductor_governed")
from fda_common import App, CFG, FDA, USE_CASE_DIR, jtmp, result_columns, setting
from tool_spec import TOOLS

RESUME_FROM = int(os.environ.get("RESUME_FROM", "0"))
BUILD_TO = int(os.environ.get("BUILD_TO", str(len(TOOLS))))
if RESUME_FROM:
    import fda_common
    fda_common.App.__init__ = lambda self, filename, out_dir=None: setattr(
        self, "file", os.path.join(out_dir or USE_CASE_DIR, filename))
app = App("SemiOrdersMCPServer.flogo", os.environ.get("OUT_DIR"))
f = app.fda
TRIG, PORT, ENDPOINT, SERVER_NAME = "SemiOrdersMCPServer", "9822", "/semiordersmcp", "SemiOrdersMCPServer"

# ---- email settings (config.md "Email Server, Username and app password" section; env wins) ----
EMAIL_USER = setting("EMAIL_USERNAME", "Username")
EMAIL_TO   = os.environ.get("EMAIL_TO") or os.environ.get("TO_EMAIL") or EMAIL_USER
SMTP_HOST  = os.environ.get("SMTP_HOST") or CFG.get("Server") or "smtp.gmail.com"
SMTP_PORT  = os.environ.get("SMTP_PORT") or CFG.get("Port") or "465"
# The #sendmail Password field is password-typed: the designer derives that from a SECRET: prefix, so a plain string
# property fails validation (wrongTypeProp). fda cannot SECRET-encrypt, so: use a SECRET: value from env/config if there
# is one, else a portable dummy blob (re-enter the app password in the designer's App Properties for live sending).
DUMMY_SECRET = "SECRET:0llnwBzNtMzA8d+RYoqdf9o6EuE="
_pw = os.environ.get("EMAIL_PASSWORD") or ""
EMAIL_PASS, EMAIL_PASS_SRC = ((_pw, "SECRET: value from env EMAIL_PASSWORD") if _pw.startswith("SECRET:")
                              else (DUMMY_SECRET, "portable dummy SECRET: blob - re-enter the app password in App Properties"))

print("fda:", FDA)
print(subprocess.run([FDA, "version"], capture_output=True, text=True).stdout.strip())
print("email password source:", EMAIL_PASS_SRC)          # never the value itself

if not RESUME_FROM:
    print("== project + PostgreSQL ==")
    f("cp", TRIG, "Arcwell Components orders & RMA MCP Server - scoped reads, guarded writes and the reviewer loop")
    app.postgres_connection()
    f("cap", "MCP_SERVER_PORT", "string", PORT)
    # email properties (used only by email_confirmation; scrub before publishing)
    f("cap", "Email_Username", "string", EMAIL_USER)
    f("cap", "Email_App_Password", "string", EMAIL_PASS)
    f("cap", "EMAIL_TO", "string", EMAIL_TO)

    print("== trigger ==")
    f("ct", TRIG, "tr_mcpserver", "Arcwell Components governed MCP server")
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


for t in TOOLS[RESUME_FROM:BUILD_TO]:
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
    f("sa", "handler", f"{TRIG}.{flow}.settings.openWorldToolHint", "--jsonValue", "false")

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

    # all readback rows go back to the caller (several tools return many rows)
    f("mm", f"{flow}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")
    if t.get("email"):
        f("mm", f"{flow}.ReturnNotSent.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")

print(f"\nMCP server build {'complete' if BUILD_TO >= len(TOOLS) else 'paused after tool ' + str(BUILD_TO)}:", app.file)
