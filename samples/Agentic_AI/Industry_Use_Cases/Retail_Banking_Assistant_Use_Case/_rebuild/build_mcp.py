#!/usr/bin/env python3
"""Build RetailBankingMCPServer.flogo with fda only (governed: scoped reads + guarded writes).
The email tool is special: it reads a SQL-validated payload (email_confirmation_payload), and a conditional
branch sends the email ONLY when the SQL says send_status == "SEND"; otherwise the flow returns the NOT_SENT
row without sending. The recipient is the To_Email app property (the configured ops inbox, as in the airline
sample); the SQL decides the content and the reported outcome, so an unauthorised call carries no account data.
Re-run:  python _rebuild/build_mcp.py      (needs the banking_governed DB; OUT_DIR=<empty dir> to replay)."""
import json, os, subprocess
from fda_common import App, FDA, jtmp, result_columns, setting
from tool_spec import TOOLS

app = App("RetailBankingMCPServer.flogo", os.environ.get("OUT_DIR"))
f = app.fda
TRIG, PORT, ENDPOINT, SERVER_NAME = "RetailBankingMCPServer", "9862", "/retail-banking-mcp", "RetailBanking"

# Portable dummy secret: Email_App_Password must be a SECRET:-prefixed value (a plain string makes the build fail
# with wrongTypeProp). Real credentials are set in the app properties at deploy/run time.
DUMMY_SECRET = "SECRET:0llnwBzNtMzA8d+RYoqdf9o6EuE="
EMAIL_USER = setting("EMAIL_USERNAME", "Username")
EMAIL_PASS = os.environ.get("EMAIL_PASSWORD") or setting("EMAIL_PASSWORD", "Password", DUMMY_SECRET)
if not EMAIL_PASS.startswith("SECRET:"):
    print("note: email password is not SECRET:-prefixed - using the portable dummy secret placeholder")
    EMAIL_PASS = DUMMY_SECRET
EMAIL_TO   = os.environ.get("TO_EMAIL") or EMAIL_USER
SMTP_HOST  = os.environ.get("SMTP_HOST") or "smtp.gmail.com"
SMTP_PORT  = os.environ.get("SMTP_PORT") or "465"

print("fda:", FDA)
print(subprocess.run([FDA, "version"], capture_output=True, text=True).stdout.strip())

print("== project + PostgreSQL ==")
f("cp", TRIG, "Kestrel Bank Retail Banking Assistant MCP Server - scoped reads and guarded writes for verified customers")
app.postgres_connection()
f("cap", "MCP_SERVER_PORT", "string", PORT)
# email properties (used only by the email tool)
f("cap", "Email_Username", "string", EMAIL_USER)
f("cap", "Email_App_Password", "string", EMAIL_PASS)
f("cap", "To_Email", "string", EMAIL_TO)

print("== trigger ==")
f("ct", TRIG, "tr_mcpserver", "Kestrel Bank Retail Banking governed MCP server")
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
            "sender": '=$property["To_Email"]', "recipients": '=$property["To_Email"]',
            "cc_recipients": "", "bcc_recipients": "", "reply_to": '=$property["Email_Username"]',
            "subject": '=$activity[ReadOutcome].Output.records[0].subject',
            "message": '=$activity[ReadOutcome].Output.records[0].body'}

SEND_COND = '$activity[ReadOutcome].Output.records[0].send_status == "SEND"'

def link_index(flow, src, dst):
    res = next(r for r in app.load()["resources"] if r["id"] == "flow:" + flow)
    return next(i for i, l in enumerate(res["data"]["links"]) if l["from"] == src and l["to"] == dst)

def branch_email(flow):
    """ReadOutcome --(send_status == "SEND")--> SendMail --> Return ;  ReadOutcome --(otherwise)--> ReturnNotSent."""
    i = link_index(flow, "ReadOutcome", "SendMail")
    f("sa", "flow", f"{flow}.links[{i}].type", "expression")
    f("sa", "flow", f"{flow}.links[{i}].value", SEND_COND, "--force")     # no leading '=' on link conditions
    f("sa", "flow", f"{flow}.links[{i}].label", "send_status is SEND")
    f("cl", flow, "ReadOutcome", "ReturnNotSent")
    j = link_index(flow, "ReadOutcome", "ReturnNotSent")
    f("sa", "flow", f"{flow}.links[{j}].type", "exprOtherwise")
    f("sa", "flow", f"{flow}.links[{j}].label", "otherwise (NOT_SENT)")
    links = next(r for r in app.load()["resources"] if r["id"] == "flow:" + flow)["data"]["links"]
    if links[i].get("type") != "expression" or links[i].get("value") != SEND_COND or links[j].get("type") != "exprOtherwise":
        raise SystemExit(f"FAILED: email branch links not set as expected: {links}")

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
    f("sa", "handler", f"{TRIG}.{flow}.settings.readOnlyToolHint", "--jsonValue", str(t["readonly"]).lower())
    f("sa", "handler", f"{TRIG}.{flow}.settings.destructiveToolHint", "--jsonValue", "false")
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

    f("mm", f"{flow}.Return.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")
    if t.get("email"):
        f("mm", f"{flow}.ReturnNotSent.input.mappings.response.mapping.data", "=coerce.toString($activity[ReadOutcome].Output)")

print("\nMCP server build complete:", app.file)
